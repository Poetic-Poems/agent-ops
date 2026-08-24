#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/standdown.sh — the stand-down reason ladder (requirement 2): every
# check a cycle runs, in order, before it commits to doing any work this
# round — the GitHub API budget and credential check, the fleet-wide
# usage-limit cooldown and its own probe, the per-cycle claim GC and orphan/
# closing-keyword/human-visibility/landing-retry/classifier-escape sweeps,
# and back-pressure across every configured repository.
#
# Split out of agent-cycle.sh (#771) as the "stand-down reason ladder" seam
# docs/IMPLEMENTATION-PIPELINE-SPEC.md's requirements name. Sourced by
# agent-cycle.sh only, and called exactly once, in place, from where this
# text used to sit: every variable it reads (`github_min_core_budget`,
# `crash_loop_repo`, `enabler_assignee`, `union_log`, …) is already set by
# the spine ahead of it, and every variable it sets (`backpressure_tripped`,
# `open_composition`, `adjusted_open_count`, `counted_prs_json`, …) is read
# by the spine after it returns — deliberately not `local`, so this call is
# indistinguishable, to the rest of the cycle, from the inline block it
# replaces. `exit 0` inside it ends the cycle exactly as it did inline: nothing
# here runs inside a subshell.
run_standdown_checks() {
# --- 2. Stand-down checks ---
# 2.0 GitHub API budget (requirement 2.0). First of the stand-down checks
# because it is the only free one: `GET /rate_limit` is exempt from the limits
# it reports, so asking costs nothing, and every check below it — the
# usage-limit probe most of all — can spend real money.
#
# What this prevents is not the failed `gh` call. It is the cycle of
# 2026-08-12T20:52Z, which read a rate-limited GitHub as a quiet one: every
# gatherer degraded to `[]`, the Co-Ordinator engaged on that digest and chose
# an item, the claim was taken, and the cycle then died at the clone with
# `GraphQL: API rate limit already exceeded`. All of that is downstream of a
# question GitHub would have answered for free before the first token was
# spent.
#
# `unknown` — the meter itself unreadable — is deliberately not a stand-down.
# It is no evidence about the budget, and a node that cannot reach
# `/rate_limit` could not have run a cycle anyway; the failure it does have
# will be reported by whatever call meets it. Standing down here would invent
# a way for a network blip to look like an exhausted account.
if (( github_min_core_budget > 0 || github_min_graphql_budget > 0 )); then
  IFS=$'\t' read -r gh_budget_verdict gh_budget_resource gh_budget_remaining gh_budget_reset_at \
    < <(github_limit_verdict "$(github_limit_snapshot || true)" \
          "$github_min_core_budget" "$github_min_graphql_budget")
  if [[ "$gh_budget_verdict" == "exhausted" ]]; then
    if [[ "$gh_budget_resource" == "core" ]]; then
      gh_budget_floor="$github_min_core_budget"
    else
      gh_budget_floor="$github_min_graphql_budget"
    fi
    log_event "stand-down" "$(jq -nc --arg r "$(github_limit_describe \
      "$gh_budget_resource" "$gh_budget_remaining" "$gh_budget_floor" "$gh_budget_reset_at")" \
      --arg res "$gh_budget_resource" --arg rem "$gh_budget_remaining" \
      --arg until "$gh_budget_reset_at" \
      '{reason: $r, github_resource: $res, github_remaining: $rem, resume_at: $until}')"
    exit 0
  fi
fi

# 2.0b GitHub credential check (requirement 2.0b, agent-ops#691). The same
# free `/rate_limit` call classifies a 401, and a missing token, apart from
# every other failure: either GitHub read the request and rejected the
# credentials outright, or `gh` had no credentials to send in the first
# place — both permanent, unlike 2.0's `exhausted` or 2.1's cooldown below,
# since no wait and no retry clears an expired, revoked or absent token.
# Checked here, ahead of the Co-Ordinator (step 4), because that stage is
# what a dead token wastes: on 2026-08-22 a node whose fine-grained PAT had
# expired ran a full Co-Ordinator engagement every cycle for ~3 hours ($1.05
# across five cycles) before a human noticed, every claim failing with
# `cause: "unreachable"` and the cycle reporting "this is an outage, not
# contention" — the one classification that sends nobody looking at the
# token. TD-PPagop-26082306 is the same fault in a different shape: a token
# unset or dropped from the environment failed the probe's stderr match too,
# so it also read as `unreachable` rather than `unauthorized`.
#
# Deliberately unconditional, unlike 2.0: a dead token is worth catching
# even on a node that has turned `github_min_core_budget` /
# `github_min_graphql_budget` off, and the call costs nothing either way
# (same free `/rate_limit` endpoint).
#
# Not routed through `escalation_autonomy` (D18, agent-ops#627): that ladder
# decides whether one specific kind of escalation — an Enabler
# refinement-disagreement (requirement 36b) — is adjudicated once before
# reaching a human. Its `adjudicate-first` path is itself a model engagement
# against GitHub, which a dead token defeats exactly as it defeats the
# Co-Ordinator; routing through it here would reintroduce the spend this
# check exists to avoid. This follows 1c's and 2.7's own precedent instead —
# an operational fact about the node, not a per-item disagreement — and
# escalates unconditionally through the same `create_escalation_issue`,
# deduplicated the same way (an open issue already naming this node's item
# ref is found, not re-filed).
IFS=$'\t' read -r gh_auth_verdict gh_auth_detail < <(github_auth_probe)
if [[ "$gh_auth_verdict" == "unauthorized" ]]; then
  # `github_auth_probe` folds two permanent faults into one verdict (2.0b's
  # own header above): a token GitHub rejected outright, and no token to send
  # at all. `detail`'s leading "no token present" (the probe's own literal
  # wording, TD-PPagop-26082306) is the only thing that tells them apart here
  # — without this branch every missing-token stand-down and escalation would
  # keep claiming a nonexistent "(HTTP 401)" and tell a human to replace a
  # token that was never set.
  if [[ "$gh_auth_detail" == "no token present"* ]]; then
    gh_auth_reason="GitHub authentication failed — no GH_TOKEN/GITHUB_TOKEN is set and gh has no stored credentials"
    auth_heading="This node has no GitHub credentials"
    auth_detail_label="detail"
    auth_title="GitHub credentials missing on node $node_name"
    auth_remedy="Nothing clears this automatically — set \`GH_TOKEN\` on this node and the next cycle proceeds normally."
    auth_warning_detail="GitHub credentials missing but the escalation issue could not be filed — will retry next cycle"
  else
    gh_auth_reason="GitHub authentication failed (HTTP 401) — GH_TOKEN is invalid or expired"
    auth_heading="GitHub rejected this node's credentials"
    auth_detail_label="GitHub's own response"
    auth_title="GitHub credentials rejected on node $node_name (HTTP 401)"
    auth_remedy="Nothing clears this automatically — replace \`GH_TOKEN\` on this node and the next cycle proceeds normally."
    auth_warning_detail="GitHub credentials rejected (401) but the escalation issue could not be filed — will retry next cycle"
  fi
  if ! (( DRY_RUN )) && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
    auth_body="$cycle_dir/auth-failure-issue.md"
    # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
    {
      printf '## %s\n\n' "$auth_heading"
      printf -- '- node: `%s`\n- cycle: `%s`\n- %s:\n\n```\n%s\n```\n\n' \
        "$node_name" "$cycle_id" "$auth_detail_label" "$gh_auth_detail"
      printf '%s\n\n' "$auth_remedy"
      printf -- '---\nItem: `auth-failure:%s` · raised by the Script · cycle `%s` · node `%s`\n' \
        "$node_name" "$cycle_id" "$node_name"
    } > "$auth_body"
    if auth_created="$(create_escalation_issue "$crash_loop_repo" "auth-failure:$node_name" \
         "$enabler_escalation_label" \
         "$auth_title" \
         "$auth_body")" && [[ -n "$auth_created" ]]; then
      log_event "auth-failure-escalated" "$(jq -nc \
        --argjson n "${auth_created%%$'\t'*}" --arg u "${auth_created#*$'\t'}" \
        '{issue_number: $n, issue_url: $u}')"
    else
      log_event "warning" "$(jq -nc \
        --arg d "$auth_warning_detail" \
        '{detail: $d}')"
    fi
  fi
  log_event "stand-down" "$(jq -nc --arg r "$gh_auth_reason" --arg d "$gh_auth_detail" \
    '{reason: $r, cause: "unauthorized", detail: $d}')"
  exit 0
fi

# 2.0c Free disk space (requirement 2.0c, agent-ops#756). Free, like 2.0 and
# 2.0b: `df -Pk` costs nothing and touches no network, so it runs ahead of
# every check below that can spend. `scripts/doctor.sh` has read
# workspace_root's free space and warned below a fixed 2 GiB since before this
# check existed — "a cycle clones every repository it touches" — but a
# warning only a human reads by hand does nothing for the cycle that clones
# into whatever room is actually left. On the ockham laptop that ran short, a
# write truncated mid-flight left zero-length git objects in both nodes'
# state mirrors, permanently disabling `git gc` (#604) and leaving 4.2 GB of
# orphaned clones behind it (#605) — starting work the host cannot finish is
# what made both possible, and this stands the cycle down before it tries.
#
# `min_free_workspace_bytes` set to `0` turns the check off. `lib/disk-
# space.sh` is the one place free space is read and judged, so doctor.sh's own
# advisory warning and this gate cannot silently disagree about what "low"
# means.
#
# An unreadable `df` is not a stand-down, the same "no evidence" reasoning
# 2.0's own `unknown` rests on: `disk_space_verdict` reads it as `ok`.
if (( min_free_workspace_bytes > 0 )); then
  disk_free_kb="$(disk_space_free_kb "$workspace_root")"
  if [[ "$(disk_space_verdict "$disk_free_kb" "$min_free_workspace_bytes")" == "low" ]]; then
    if [[ "$disk_free_kb" =~ ^[0-9]+$ ]] && (( disk_free_kb == 0 )); then
      disk_standdown_cause="disk-full"
    else
      disk_standdown_cause="disk-low"
    fi
    log_event "stand-down" "$(jq -nc \
      --arg r "$(disk_space_describe "$workspace_root" "$disk_free_kb" "$min_free_workspace_bytes")" \
      --arg cause "$disk_standdown_cause" --arg path "$workspace_root" --arg free_kb "$disk_free_kb" \
      '{reason: $r, cause: $cause, path: $path, free_kb: $free_kb}')"
    exit 0
  fi
fi

# 2.1 Usage-limit cooldown (fleet-wide: every node shares one Claude account,
# so a limit any node hit stands this one down too). Two carriers of the same
# signal, and the later resume wins: the log union is as fresh as the last
# state-sync fetch, while fleet/limit.json is read live — it is what lets a
# limit one node hit a minute ago stop this cycle now, not a fetch interval
# from now. Either carrier can be retired early — automatically by the probe
# of 2.1b below when the resume time is this system's own guess, or by hand
# with `--clear-limit` (2.1) — and both retirements work the same way: the
# union's reduction honours a `limit-cleared` event, and the flag is deleted
# outright.
#
# Both records are carried whole rather than reduced to a timestamp, so the
# logged reason can say whether `resume_at` is a stated reset or this system's
# own guess. Reporting a guess as a deadline is what let a stale stand-down
# outlive the limit that caused it and go unquestioned.
union_record=""
if [[ -s "$union_log" ]]; then
  union_record="$(limit_union_record < "$union_log")"
fi
governing="$(limit_later_record "$union_record" "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)")"
[[ -n "$governing" ]] || governing='{}'
resume_at="$(jq -r '.resume_at // empty' <<<"$governing" 2>/dev/null || true)"
resume_epoch=0
if [[ -n "$resume_at" ]]; then
  # TD-PPagop-26081407: `governing` is fleet state read across nodes above
  # (test 1); epoch 0 reads as "already expired" (test 2) -- the gate this
  # feeds decides whether the whole fleet stands down for an active limit.
  resume_epoch="$(date -d "$resume_at" +%s 2>&1)" \
    || { guard_warn "cycle:resume_epoch" "$resume_epoch"; resume_epoch=0; }
fi
now_epoch="$(date +%s)"
if (( resume_epoch > now_epoch )); then
  governing_class="$(jq -r '.class // "other"' <<<"$governing" 2>&1)" \
    || { guard_warn "cycle:governing_class" "$governing_class"; governing_class=other; }
  governing_known="$(limit_reset_known "$governing")"
  # Absent means auto: every record this system writes is a detector's, and
  # says so; `manual` only ever enters by an operator's hand. The distinction
  # is load-bearing in both directions (requirement 2; #244) — an automatic
  # stand-down may be probed and cleared early, a manual one must never be.
  governing_kind="$(jq -r '.kind // "auto"' <<<"$governing" 2>&1)" \
    || { guard_warn "cycle:governing_kind" "$governing_kind"; governing_kind=auto; }
  standing=1
  probe_note=""
  # 2.1b The estimated stand-down probes its own exit. When `reset_known` is
  # false, `resume_at` is this system's invented time and carries no
  # information about the limit — and the observed spend-cap message is
  # emitted equally when a 5-hour session window meets an exhausted cap,
  # which clears at the session rollover, most of a day before the invented
  # time (it did, on 2026-07-28: both hits cleared within the hour; the fleet
  # would have slept 24). So instead of sleeping on a guess, spend one
  # minimal invocation of the cheapest model asking the only authority there
  # is. The economics run the right way round on both sides: a limited
  # account answers the probe with the limit message at no token cost, and an
  # unlimited one answers for a fraction of a cent, once — the first clear
  # verdict retires the stand-down for the whole fleet, and the gate stops
  # firing. A *stated* reset is never probed: the message named the time, and
  # asking earlier is the one spend that buys nothing. Nor does --dry-run
  # probe: a cycle that promises to change nothing must not write
  # `limit-cleared`, and a probe whose verdict it would have to ignore is
  # pure cost. And a *manual* record is never probed at all: it is an
  # operator's decision, not a detector's inference, and no probe verdict is
  # evidence about whether the human still means it (#244).
  if [[ "$governing_kind" != "manual" && "$governing_known" != "true" ]] && ! (( DRY_RUN )); then
    probe_out="$cycle_dir/limit-probe.out"
    run_claude_stage limit-probe 180 "$implementer_model_trivial" \
      "Reply with the single word: ok" "$probe_out" "$cycle_dir" || true
    probe_verdict="$(limit_probe_verdict "$(cat "$probe_out" 2>/dev/null || true)" \
      "$(cat "$probe_out.stderr" 2>/dev/null || true)")"
    case "$probe_verdict" in
      clear)
        # The same two carriers --clear-limit retires, for the same reason it
        # retires both: the stand-down lifts only when the later of the two
        # says so. The `limit-cleared` event outranks every earlier hit in
        # the union's reduction; the flag is deleted because
        # fleet_limit_publish is extend-only and delete is the one write that
        # legitimately moves a resume earlier.
        log_event "limit-cleared" "$(jq -nc --arg w "$resume_at" \
          --arg by "auto-probe@$node_name" --arg n "$node_name" \
          '{was: $w, reason: "probe answered: the limit behind this estimated stand-down is gone", by: $by, actor: $n, kind: "auto"}')"
        if [[ -n "$state_repo" ]]; then
          # >/dev/null: fleet_flag_delete now prints which of "deleted"/
          # "absent" it was (issue #426); this site only reads the return
          # code, and the raw word must not leak into the cycle's own stdout.
          fleet_flag_delete "$state_repo" "$state_dir" limit >/dev/null || log_event "warning" \
            '{"detail": "could not clear fleet/limit.json after a clear probe — peers reading it live stand down until their own probes answer"}'
        fi
        standing=0
        ;;
      limited)
        # The probe just observed the limit live, which is worth recording
        # for two reasons: the Enabler must not be engaged from the exit trap
        # moments after a limit was re-confirmed (requirement 35's guards),
        # and the probe's transcript may state what the original message did
        # not — a parseable reset upgrades `reset_known` to true and stops
        # the probing until a time that is finally real.
        detect_and_log_limit_hit "$probe_out" || true
        probe_note=" (probe: still limited)"
        ;;
      *)
        probe_note=" (probe: inconclusive)"
        ;;
    esac
  fi
  if (( standing )); then
    if [[ "$governing_kind" == "manual" ]]; then
      # An operator's stand-down explains itself and is honoured as written:
      # no probe ran above, nothing here clears it, and it ends at its own
      # resume_at or when the human runs --clear-limit (#244).
      governing_actor="$(jq -r '.actor // .node // "?"' <<<"$governing" 2>&1)" \
        || { guard_warn "cycle:governing_actor" "$governing_actor"; governing_actor='?'; }
      standdown_reason="manual stand-down until $resume_at, set by $governing_actor — never probed or auto-cleared; 'agent-cycle.sh --clear-limit' lifts it early"
    else
      standdown_reason="usage-limit cooldown $(limit_describe "$resume_at" \
        "$governing_class" "$governing_known")$probe_note"
      # #244: a long-running *automatic* fleet-wide freeze is put in front of
      # a human — the operator did not choose it, so nobody is watching it —
      # while a manual stand-down never pages the person who set it. Aged
      # from the start of the current freeze (limit_standdown_since), not
      # from its latest extension, and raised once per freeze: the
      # `limit-freeze-escalated` event in the union is the memory, and
      # create_escalation_issue's open-issue guard catches the cross-node
      # race the union has not yet carried.
      if (( limit_escalate_after_hours > 0 )) && ! (( DRY_RUN )) \
         && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
        freeze_since="$(limit_standdown_since < "$union_log")"
        freeze_epoch="$(date -d "$freeze_since" +%s 2>&1)" \
          || { guard_warn "freeze_epoch" "$freeze_epoch"; freeze_epoch=0; }
        freeze_done="$(jq -c --arg s "$freeze_since" \
          'select(.event == "limit-freeze-escalated" and .since == $s)' \
          "$union_log" 2>/dev/null | head -n1 || true)"
        if [[ -z "$freeze_done" ]] && (( freeze_epoch > 0 )) \
           && (( now_epoch - freeze_epoch >= limit_escalate_after_hours * 3600 )); then
          freeze_body="$cycle_dir/limit-freeze-issue.md"
          # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
          {
            printf '## The fleet has been standing down automatically since %s\n\n' "$freeze_since"
            printf 'Every cycle since then has stood down on an automatic usage-limit record, and the freeze has now outlived `limit_escalate_after_hours` (%s h). The governing record:\n\n' "$limit_escalate_after_hours"
            printf '```json\n%s\n```\n\n' "$governing"
            printf 'If the limit is real, nothing is needed — the stand-down ends at its own resume time, and each cycle keeps probing an estimated one. If it has lapsed or was misread, `agent-cycle.sh --clear-limit <reason>` lifts it fleet-wide.\n\n'
            printf -- '---\nItem: `usage-limit-freeze:%s` · raised by the Script · cycle `%s` · node `%s`\n' \
              "$freeze_since" "$cycle_id" "$node_name"
          } > "$freeze_body"
          if freeze_created="$(create_escalation_issue "$crash_loop_repo" \
               "usage-limit-freeze:$freeze_since" "$enabler_escalation_label" \
               "Usage-limit freeze: the fleet has stood down automatically since $freeze_since" \
               "$freeze_body")" && [[ -n "$freeze_created" ]]; then
            log_event "limit-freeze-escalated" "$(jq -nc \
              --argjson n "${freeze_created%%$'\t'*}" --arg u "${freeze_created#*$'\t'}" \
              --arg s "$freeze_since" '{issue_number: $n, issue_url: $u, since: $s}')"
          else
            log_event "warning" "$(jq -nc \
              --arg d "automatic usage-limit freeze since $freeze_since exceeds ${limit_escalate_after_hours}h but the escalation issue could not be filed — will retry next cycle" \
              '{detail: $d}')"
          fi
        fi
      fi
    fi
    log_event "stand-down" "$(jq -nc --arg r "$standdown_reason" '{reason: $r}')"
    exit 0
  fi
fi

# 2.1a Claim GC — sweep registry entries older than claim_ttl_hours (17a).
# Every node runs it, because it needs no coordination: a registry delete is
# sha-guarded, and a claim branch is deleted only if it is unmoved AND has no
# PR, so the worst race outcome is a no-op. Runs before 2.2 so the count
# there does not include entries this sweep just retired. Skipped on
# --dry-run: a cycle that promises to change nothing must not delete refs.
if ! (( DRY_RUN )); then
  "$SCRIPT_DIR/lib/claim.sh" gc >>"$cycle_dir/claim.log" 2>&1 || true
fi

# 2.1b Orphan-branch sweep (requirement 17b) — the state the gc above leaves
# behind on purpose. Retiring a moved branch's registry entry while keeping
# its ref is right for the work (pushed commits are never deleted) and wrong
# for the item: with no PR, nothing ever finds those commits again, every
# later claim 422s against the live ref, and the Co-Ordinator's exclusion
# reads it as "claimed, skip" — the item is wedged and nothing has said so.
# The sweep turns each provable orphan back into a state the pipeline already
# handles: a draft PR the abandoned-drafts source recovers, or (for a ref
# with nothing on it) no ref at all. Every node runs it, like the gc and for
# the same reason: GitHub rejects a second PR for the same head and a second
# ref delete is a no-op, so the worst race outcome is a warning. Fleet-wide
# like the gc, regardless of --repo. Skipped on --dry-run: the sweep opens
# PRs and deletes refs.
if ! (( DRY_RUN )); then
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        recovered) log_event "orphan-branch-recovered" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        released)  log_event "orphan-branch-released" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("orphan-branch sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-orphan-branches.sh" "$sweep_slug" \
               2>>"$cycle_dir/orphan-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.1c Post-merge closing-keyword sweep (requirement 17c) — the backstop for
# requirement 25a's CI check: a merged, `pr_label`-labelled pull request that
# named an issue (the `agent-ops:closes-issue` marker, requirement 23b) but
# never carried a real closing keyword leaves that issue open forever, to be
# re-selected and re-voided by every cycle that reaches it (issue #240; PR
# #206's "Implements #198" kept #198 open three days after its own fix
# merged). Cheap and bounded — scripts/sweep-closed-issues.sh examines only
# the most recently updated merged PRs per repo — and idempotent by
# construction: it only ever acts on an issue GitHub itself still reports
# open. Fleet-wide like 2.1a/2.1b, regardless of --repo. Skipped on
# --dry-run: the sweep closes issues.
if ! (( DRY_RUN )); then
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        closed) log_event "issue-closed-post-merge" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("closed-issue sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-closed-issues.sh" "$sweep_slug" "$node_name" "$cycle_id" \
               2>>"$cycle_dir/closed-issue-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.1d Human-visibility sweep (requirement 38) — the periodic half of the same
# guarantee requirement 38a keeps at the moment of handoff: every open, ready
# pull request this system raised gets a live review request whether or not
# any stage touched it this cycle, and an approved, mergeable, green one idle
# past `human_nudge_idle_hours` gets one nudge comment. Fleet-wide like the
# sweeps above and for the same reason — a review request or a comment either
# lands or it does not, so two nodes sweeping at once cost nothing but a
# redundant read. Skipped on --dry-run: the sweep requests reviews and posts
# comments.
#
# Its actions get their own event names rather than borrowing `pr-ready`, for
# the same reason 2.1b's do: the Publisher's outcome ladder reads `pr-ready` as
# "this cycle got a pull request to ready" and ranks it above every other
# reading, so a sweep that re-asked for a review on some other repo's
# long-since-ready pull request would rewrite the outcome of a cycle that stood
# down or selected nothing.
#
# Its `warning` events are appended into `union_log` the moment the sweep
# finishes (below), the same technique requirement 34j's own reconciliation
# uses to see its own cycle's freshly-logged events: `human_visibility_json`,
# computed later this cycle from `union_log` (requirement 38e), must see a
# violation this very sweep just found, not only one a previous cycle logged —
# otherwise the register-hygiene pre-fetch a few hundred lines below would
# never catch what its own cycle's sweep just discovered, and the violation
# would sit one full cycle behind its own detection for no reason.
if ! (( DRY_RUN )); then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        human-review-requested) log_event "human-review-requested" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        nudged) log_event "human-nudged" "$(jq -c --arg r "$sweep_slug" \
          '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        dequeue-notice) log_event "human-dequeue-notice" "$(jq -c --arg r "$sweep_slug" \
          '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("human-visibility sweep (" + $r + "): " + (del(.action) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-human-visibility.sh" "$sweep_slug" "$cycle_id" "$node_name" \
               2>>"$cycle_dir/human-visibility-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

# Approver restale sweep (requirement 46, agent-ops#682) — a pull request the
# Approver refused whose own review has since gone stale (the Implementer
# answered it and pushed, but the cycle that pushed never lived long enough
# to reach its own Reviewer-then-Approver continuation) otherwise sits behind
# GitHub's own `requested_reviewers`, which silently no-ops for the
# Approver's Bot identity and so can never itself clear it — see
# `_approver_restale_sweep_repo`'s own header for the full candidate rule.
# Fleet-wide regardless of `--repo`, same as every sweep in this section: any
# repository at `merge_autonomy` above `human` may have one. Run before the
# landing-retry sweep below on purpose — a pull request this sweep freshly
# re-approves becomes exactly the standing-`APPROVED` candidate that sweep's
# own precondition looks for, so a genuine fix can clear both gaps in the one
# cycle that finds it rather than waiting a further cycle for the second.
# Skipped on `--dry-run`: it can post a review, dismiss one, or escalate.
if ! (( DRY_RUN )); then
  if restale_login="$(approver_token_identity_login "")" && [[ -n "$restale_login" ]]; then
    while IFS= read -r restale_slug; do
      [[ -n "$restale_slug" ]] || continue
      _approver_restale_sweep_repo "$restale_slug" "$restale_login"
    done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  fi
fi

# 2.1e Landing-retry sweep (TD-PPagop-26081701) — the tracked gap "## The
# Landing Gate" and requirement 8d gate 5 both name: a pull request the
# arming step already approved once, but could not land for a reason that
# can change without the pull request itself changing (the merge budget
# resetting, the kill switch or a per-repo freeze lifting, a
# `merge_autonomy`/`merge_autonomy_routine_sources` config change, a
# transient unreadable, a red required check going green), otherwise sits
# there until a human merges it by hand — forever, for the fail-closed
# unreadables. `_landing_retry_sweep_repo` (below) re-enters
# `_landing_stage_attempt`'s own seven gates verbatim for each candidate (RETRY
# set), rather than a second copy of them. Fleet-wide like the sweeps above,
# regardless of --repo: any repository at `agent-merges-routine` or above may
# have a stranded, Approver-approved pull request waiting. Skipped on
# --dry-run: it can land a pull request. `approver_token_identity_login` is
# asked once, fleet-wide (the Approver App's own login does not vary by
# repository), rather than once per repository as `_landing_stage_attempt`'s
# own gate 4 already does per pull request — an unreadable login here means
# nothing in the sweep can confirm a standing review, so the whole sweep is
# skipped for the cycle rather than every repository paying for the same
# unreadable credential.
if ! (( DRY_RUN )); then
  if retry_login="$(approver_token_identity_login "")" && [[ -n "$retry_login" ]]; then
    while IFS= read -r sweep_slug; do
      [[ -n "$sweep_slug" ]] || continue
      _landing_retry_sweep_repo "$sweep_slug" "$retry_login"
    done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  fi
fi

# 2.1f Classifier-escape audit (D18 Stage 2 exit criterion "zero classifier
# escapes"; agent-ops#572) — nothing above re-checks the *outcome* of a
# landing, only the decision that produced it: `scripts/detect-classifier-
# escapes.sh` is the independent, read-only audit, deliberately reimplementing
# `lib/landing.sh`'s protected-path list and never calling `landing_eligible`
# (its own header explains why), rather than being sourced or trusted the
# way `_landing_retry_sweep_repo` above reuses the real gates verbatim — an
# audit that shared the code it exists to check could not catch a bug in
# that shared code. Same sweep shape as `scripts/sweep-human-visibility.sh`
# (above): stdout is one JSON object per newly-audited pull request, this
# loop is what actually appends anything to the log — a standalone script
# never may, per requirement 33's single-writer rule. Fleet-wide regardless
# of `--repo`, and safe on `--dry-run`: it never arms or lands anything,
# only reads GitHub's own merged-PR record and the fleet log. Run every
# cycle rather than gated on `merge_autonomy`: idempotent against its own
# prior findings (LOG_FILE) for any pull request this repository has already
# produced a `classifier-escape`/`landing-audit`/`landing-audit-skip` event
# for, regardless of who merged it — a repository sitting below
# `agent-merges-routine`, where a merge under the Approver identity is rare
# or never happens, still pays the one `repos/SLUG/pulls/N` read each such
# pull request needs to learn who merged it, but only once: that fact is
# recorded (as `outcome: "not-approver"`, logged below as
# `landing-audit-skip`) exactly like an audited landing is, so it is never
# paid again on a later cycle. `timeout 120` bounds what a single cycle
# spends on this either way, and while a repository with a large backlog of
# never-yet-recorded pull requests may need several cycles to work through
# it, each cycle's budget goes further than the last rather than being
# pinned at a permanent frontier — see the script's own "Idempotency"
# section for what oldest-first candidate order buys and for the size of
# that backlog on this repository as of 2026-08-22. The same
# unreadable-login skip the retry sweep above uses applies here too — with
# no Approver identity to test `merged_by` against, nothing below could
# tell an autonomous landing apart from a human's own merge.
if escape_login="$(approver_token_identity_login "")" && [[ -n "$escape_login" ]]; then
  while IFS= read -r escape_slug; do
    [[ -n "$escape_slug" ]] || continue
    escape_log_lines_before="$(wc -l < "$log_file" 2>&1)" \
      || { guard_warn "escape_log_lines_before" "$escape_log_lines_before"; escape_log_lines_before=0; }
    while IFS= read -r escape_action; do
      [[ -n "$escape_action" ]] || continue
      case "$(jq -r '.outcome // ""' <<<"$escape_action" 2>/dev/null || true)" in
        escape) log_event "classifier-escape" "$(jq -c 'del(.outcome)' <<<"$escape_action")" ;;
        clean|unverifiable) log_event "landing-audit" "$(jq -c '.' <<<"$escape_action")" ;;
        not-approver) log_event "landing-audit-skip" "$(jq -c '.' <<<"$escape_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/detect-classifier-escapes.sh" \
               "$escape_slug" "$escape_login" "$union_log" --config "$CONFIG_FILE" \
               2>>"$cycle_dir/classifier-escape-audit.err" || true)
    tail -n "+$(( escape_log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.2 Back-pressure — across ALL configured repos, regardless of --repo.
#
# The stand-down is *deferred* rather than taken here (requirement 2.2a). Back-
# pressure throttles starting new work, and until the sources are gathered we do
# not know whether the only candidate is review-feedback — which finishes work
# already parked in whichever queue requirement 2.2's merge_autonomy-aware
# exclusion currently holds it in (a human's, below agent-merges-routine; see
# D18 WI-6 below) instead of adding to it. Standing down here would
# deadlock the pipeline exactly when it is most stuck: max_open_agent_prs PRs
# all waiting on the agent, and the one source that could clear them never
# reached. The cost of deferring is the handful of `gh` calls in step 3.
#
# A ready PR only counts toward the trip when the pipeline itself has a next
# action on it — `reviewDecision == CHANGES_REQUESTED`, the same "whose turn
# is it" rule requirement 3c's review-feedback candidate filter uses
# (scripts/gather-review-feedback.sh), so the two definitions cannot disagree.
# A ready PR that is approved, or awaiting a first or re-review with nothing
# currently `CHANGES_REQUESTED`-blocking it, is sitting in a human's queue only
# below agent-merges-routine (D18 WI-6, the level-aware loop below) — the
# pipeline cannot shrink that queue by declining to open new work, so counting
# it against the cap only back-pressures the fleet for a queue it has no lever
# to drain (agent-ops#246). At agent-merges-routine and above there is no such
# queue for it to sit in, and it counts like any other ready PR (see
# `backpressure_autonomous_rank` below).
#
# The count is taken in four parts — ready PRs awaiting a human (only below
# agent-merges-routine; see D18 WI-6 below), ready PRs awaiting the pipeline,
# draft PRs, live claims — because the trip decision needs only the
# human-queue-excluded sum, but the logged reason states the full split: a
# human-queue PR could fill the raw total without ever counting against the
# cap, at levels where such a queue exists; a pipeline-turn ready PR is that
# queue answered (or, at agent-merges-routine and above, simply the next
# ready PR) and now the agent's to act on; a draft is work in flight (the
# Implementer's own claim marker, requirement 23); an unraised claim is a
# registry entry whose PR does not yet exist. Which of them filled the gate
# is what a cap-tuning decision needs to know. Recording it here costs
# nothing; reconstructing it later means cycle-record archaeology.
#
# The listing's page size is stated (`GITHUB_PR_LIST_LIMIT`, lib/github-limit.sh)
# rather than left to `gh`'s undeclared default of 30, and a response that came
# back at it is treated as a trip. This is the one place in the pipeline where
# a truncated listing is actively dangerous: `gh` gives no signal that it
# capped, so the counts below would simply be low, and low counts open a gate
# whose whole purpose is to stay shut. Note that the raw listing is not bounded
# by `max_open_agent_prs` — a pull request sitting in whichever queue
# requirement 2.2's merge_autonomy-aware exclusion currently parks it in still
# carries `pr_label` and is deliberately excluded from the sum — so a repo can
# genuinely hold more open labelled PRs than the cap, and the cap is no
# guarantee the page was big enough.
#
# Live claims count toward the cap too: a claim is work in flight that has
# not yet surfaced as a PR, and N nodes counting only PRs would collectively
# overshoot by the work each other had claimed but not yet raised. Still
# approximate — two nodes can pass this check simultaneously — with a stated
# bound of max_open_agent_prs + (nodes - 1), transient.
#
# "Not yet surfaced as a PR" is the whole of it, and it is why each repo's
# claims are counted *here*, inside the same iteration as its own PR listing,
# rather than in a second loop of their own: `claim.sh count` is told which of
# this repo's pull requests the sum above already holds, and drops any claim
# that merely names one of them. Two claim shapes name a PR. The PR-keyed
# `pr-<n>` exclusion entry (issue #238) is held past its PR's own raising
# (issue #360) and `claim.sh` drops it unconditionally; the item claim beside
# it carries the `pr-<n>-<kind>-<scope>` ref the four finishing sources use,
# and until now it was counted — a claimed abandoned draft was its own draft
# PR *plus* its own claim, two against a cap it occupies once. Only the PRs
# actually inside the sum are passed, so a conflicted or dequeued PR that the
# rule above leaves out of the sum keeps counting through its claim, which is
# then the only record of it in flight.
ready_count=0
human_queue_count=0
draft_count=0
claim_count=0
listing_truncated=0
# Per-repo set of PR numbers this count already holds — its drafts and its
# CHANGES_REQUESTED-ready PRs, the same rule `counted_prs` below applies one
# repo at a time. An object keyed by slug, each value a JSON array of PR
# numbers. Requirement 2.2a's decision site reads this back to tell which of
# a repo's merge-conflict/dequeued candidates (gathered later, in step 3, so
# they cannot be folded in above) this count already counted and which it did
# not.
counted_prs_json='{}'
# The rank a repo's effective merge_autonomy level must reach for this loop
# to stop excluding its ready, non-CHANGES_REQUESTED pull requests (D18 WI-6,
# requirement 2.2's own level-aware paragraph) — loop-invariant, so it is
# resolved once rather than once per repo.
backpressure_autonomous_rank="$(merge_autonomy_rank agent-merges-routine)"
while IFS= read -r slug; do
  # D18 WI-6 (requirement 2.2's own level-aware paragraph): above
  # agent-merges-routine there is no human queue for a ready, non-
  # CHANGES_REQUESTED pull request to sit in, so nothing is excluded from
  # this repo's count below. Read once per repo, against the effective level
  # (never the configured one — merge_autonomy_effective_level is the one
  # function every reader of this key must go through), so a fleet-wide kill
  # switch or a merge-budget freeze (requirement 2.3c) un-excludes those pull
  # requests again by the next cycle's process — this read is advisory, not
  # an acting site, so it is memoised for this process's whole run like every
  # other advisory read (requirement 2.3a, issue #513).
  slug_level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir")"
  slug_level_rank="$(merge_autonomy_rank "$slug_level" 2>/dev/null)" || slug_level_rank=0
  prs_json="$(gh pr list -R "$slug" --state open --label "$pr_label" \
    --limit "$GITHUB_PR_LIST_LIMIT" --json number,isDraft,reviewDecision 2>/dev/null)" || prs_json=''
  [[ -n "$prs_json" ]] || prs_json='[]'
  counts="$(jq -r '[([.[] | select(.isDraft | not)] | length),
           ([.[] | select(.isDraft | not) | select(.reviewDecision != "CHANGES_REQUESTED")] | length),
           ([.[] | select(.isDraft)] | length),
           length] | @tsv' <<<"$prs_json" 2>/dev/null)" || counts=''
  IFS=$'\t' read -r n_ready n_human n_draft n_total <<<"$counts"
  [[ "$n_ready" =~ ^[0-9]+$ ]] || n_ready=0
  [[ "$n_human" =~ ^[0-9]+$ ]] || n_human=0
  [[ "$n_draft" =~ ^[0-9]+$ ]] || n_draft=0
  [[ "$n_total" =~ ^[0-9]+$ ]] || n_total=0
  if (( slug_level_rank >= backpressure_autonomous_rank )); then
    n_human=0
  fi
  if github_pr_list_truncated "$n_total"; then
    listing_truncated=1
    log_event "warning" "$(jq -nc --arg r "$slug" --arg l "$GITHUB_PR_LIST_LIMIT" --arg d \
      "back-pressure: $slug's open labelled pull requests came back at the ${GITHUB_PR_LIST_LIMIT}-item listing cap, so the count below is a floor, not a total; treating back-pressure as tripped rather than counting a truncated page" \
      '{repo: $r, limit: $l, detail: $d}')"
  fi
  ready_count=$(( ready_count + n_ready ))
  human_queue_count=$(( human_queue_count + n_human ))
  draft_count=$(( draft_count + n_draft ))
  # The pull requests this repo just contributed to the trip: its drafts, and
  # its ready ones the pipeline still owes a change — every ready one, at
  # agent-merges-routine or above, where n_human was just zeroed above for
  # the same reason. Bounded by GITHUB_PR_LIST_LIMIT, so it may ride argv
  # (requirement 4g). An unreadable listing leaves it empty, which counts
  # every claim — the fail-closed reading, matching the zeroed counts above.
  if (( slug_level_rank >= backpressure_autonomous_rank )); then
    counted_prs_array="$(jq -c '[.[].number]' <<<"$prs_json" 2>/dev/null)" || counted_prs_array='[]'
  else
    counted_prs_array="$(jq -c '[.[] | select(.isDraft or .reviewDecision == "CHANGES_REQUESTED") | .number]' \
      <<<"$prs_json" 2>/dev/null)" || counted_prs_array='[]'
  fi
  [[ -n "$counted_prs_array" ]] || counted_prs_array='[]'
  counted_prs="$(jq -r 'join(",")' <<<"$counted_prs_array" 2>/dev/null)" || counted_prs=''
  counted_prs_json="$(jq -c --arg s "$slug" --argjson ns "$counted_prs_array" \
    '. + {($s): $ns}' <<<"$counted_prs_json" 2>/dev/null)" || counted_prs_json='{}'
  n="$("$SCRIPT_DIR/lib/claim.sh" count "$slug" "$counted_prs" 2>&1)" \
    || { guard_warn "claim-count:$slug" "$n"; n=0; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  claim_count=$(( claim_count + n ))
done < <(jq -r '.[].slug' <<<"$all_repos_json")

pipeline_ready_count=$(( ready_count - human_queue_count ))
raw_open_count=$(( ready_count + draft_count + claim_count ))
adjusted_open_count=$(( pipeline_ready_count + draft_count + claim_count ))
open_composition="$pipeline_ready_count changes-requested + $draft_count draft + $claim_count unraised claim(s) — plus $human_queue_count waiting on human ($raw_open_count raw)"

backpressure_tripped=0
if (( adjusted_open_count >= max_open_agent_prs )); then
  backpressure_tripped=1
fi
# A truncated listing trips the gate on its own, whatever the visible sum came
# to: the counts are a floor and the real total is unknown, and of the two ways
# to be wrong — deferring a cycle that could have run, or opening work past a
# cap that was already full — only the first is recoverable next cycle.
if (( listing_truncated )); then
  backpressure_tripped=1
  open_composition="$open_composition — at least one repo's listing was truncated, so these are floors"
fi

}
