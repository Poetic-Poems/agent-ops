#!/usr/bin/env bash
#
# lib/labels.sh — the pipeline creates its own labels in the repositories it
# works, rather than requiring a human to create them first.
#
# Every label this system applies is one an operator had to create by hand, in
# every target repository, before it would do anything. Nothing failed loudly
# when they had not: `refinement_label_add` swallows the error and records the
# block anyway, `create_escalation_issue` retries without the label, and the
# item goes on being handled while the *signal to the human* — the thing the
# label exists to be — silently does not appear. Poetic's own installation had
# drifted exactly that way by August 2026: three of its repositories were
# missing between one and four of the labels the pipeline projects onto their
# items, and no cycle had ever said so.
#
# That is a product bug rather than a Poetic quirk (the customer-zero rule in
# docs/ROADMAP.md): a new installation should not need a checklist of `gh label
# create` commands to be functional, and a label a human deletes should come
# back on its own. So the Script ensures its labels exist in a repository at
# the point it is about to work it — one cheap listing, and a create only for
# what is genuinely absent.
#
# Two properties are deliberate:
#
#   - **It only ever creates.** A label that already exists is left exactly as
#     it is, whatever its colour or description. Operators recolour and
#     re-describe labels, and a pipeline that reasserted its own idea of them
#     every cycle would be undoing that work on a schedule.
#   - **It can never fail a cycle.** A repository this cannot list, or a token
#     without permission to create, yields a report and nothing else. The
#     tolerances the callers already carry stay exactly where they are: this
#     makes the common case work, it does not become a new thing that breaks.
#
# Sourced by agent-cycle.sh and review-cycle.sh.

# The product's own labels, with the colour and description a fresh
# installation gets. Names come from config — an installation may rename any of
# them — but a name it does not set (the empty value that switches a projection
# off) yields nothing to create.
#
# `blocked` is the exception that proves the interface: it is not
# configurable, and is read by scripts/gather-issues.sh as an exclusion.
# Originally applied only by a human; since agent-ops#639 the Script projects
# it too, onto the issue behind a needs-refinement block (requirement 38b),
# alongside `blocked:needs-refinement` naming why — a fixed pair, also not
# configurable, that replaced assigning `enabler_assignee` to that same issue.
# Creating both is how an installation gets the human-hand-applied control at
# all — a repository without the label offers the human no way to say "not
# this one" — and is what lets the Script's own projection reach a repository
# it has not otherwise ensured labels in yet.
# `obsolete` is the same kind of exception, for the same reason: it is not
# configurable, and no pipeline stage may ever apply it — lib/void-guard.sh's
# `void_finishing_pr_reason` reads it as a human's own corroboration that a
# still-open, still-diff-carrying `pr-<n>-abandoned-…`/`pr-<n>-review-…` draft
# is genuinely unwanted, and a stage that could apply the label itself could
# corroborate its own judgement with it (TD-PPagop-26081308).

# labels_catalogue CONFIG_FILE SCHEMA_FILE ROLE [REVIEW_PR_LABEL]
# Print the labels a repository in ROLE needs, one per line, as
# `name<TAB>colour<TAB>description`. ROLE is one of:
#   target      — a repository the implementation pipeline works
#   review      — a repository the project-review pipeline reviews
#   escalation  — where escalation issues are filed (crash_loop_repo)
#
# REVIEW_PR_LABEL is used only for ROLE "review": project_review's pr_label is
# resolved per repository (requirement 342 — an entry in `project_review.repos`
# may override `project_review.defaults.pr_label`), so there is no longer one
# global value this function could read out of the config itself. The caller
# already knows the specific repository's effective label — review-cycle.sh
# resolves it once per repo, scripts/doctor.sh once per configured entry — and
# passes it through here rather than this function re-deriving a single value
# that no longer exists.
#
# Reads config_defaults's merge rather than CONFIG_FILE directly (issue #197),
# so the label names below take config.schema.json's `default` without
# repeating it here; config_defaults is assumed sourced by the caller, as
# every caller of this file already sources lib/config-schema.sh.
labels_catalogue() {
  local config_file="$1" schema_file="$2" role="$3" review_pr_label="${4:-}" defaulted
  defaulted="$(config_defaults "$config_file" "$schema_file" 2>/dev/null)" || return 0
  jq -r --arg role "$role" --arg review_pr_label "$review_pr_label" '
    def entry($name; $colour; $description):
      if ($name // "") == "" then empty
      else [$name, $colour, $description] end;

    (if $role == "target" then
       [ entry(.pr_label; "1d76db";
               "Raised by the autonomous implementation pipeline"),
         entry(.enabler_escalation_label; "b60205";
               "Raised by the Enabler: a blocked item that needs a human"),
         entry(.needs_refinement_label; "fbca04";
               "Too under-specified to work on; say what done looks like"),
         entry(.refined_label; "0e8a16";
               "The Refiner has written this a specification"),
         entry(.unvoid_label; "0e8a16";
               "Apply to ask the pipeline to reconsider an item it voided"),
         entry("blocked"; "d93f0b";
               "Keeps the pipeline from selecting this issue; hand-applied or Script-projected (38b)"),
         entry("blocked:needs-refinement"; "fbca04";
               "Projected alongside `blocked`: too under-specified to work on, say what done looks like (38b)"),
         entry("obsolete"; "cfd3d7";
               "Apply to a still-open, still-diff-carrying draft pull request the pipeline raised to say it is no longer wanted; no pipeline stage ever applies this"),
         entry("complexity:low"; "c2e0c6";
               "Graded by the Implementer; picks the Reviewer tier"),
         entry("complexity:medium"; "fef2c0";
               "Graded by the Implementer; picks the Reviewer tier"),
         entry("complexity:high"; "f9d0c4";
               "Graded by the Implementer; picks the higher Reviewer tier") ]
     elif $role == "review" then
       [ entry($review_pr_label; "5319e7";
               "Raised by the project-review pipeline") ]
     elif $role == "escalation" then
       [ entry(.enabler_escalation_label; "b60205";
               "Raised by the Enabler: a blocked item that needs a human") ]
     else [] end)
    | .[] | @tsv
  ' <<<"$defaulted" 2>/dev/null || true
}

# labels_ensure REPO < CATALOGUE
# Create, in REPO, every label on stdin that is not there already. Prints one
# `created<TAB>name` line per label it made and one `failed<TAB>name` per label
# it could not, and nothing at all for those already present — so a caller can
# log the exceptions and stay silent in the steady state, which is every cycle
# after the first.
#
# Returns 0 whenever the repository's labels could be listed, whatever happened
# to the individual creates, and 1 when they could not. Even that 1 is
# advisory: no caller may treat it as fatal, because a label is a signal to a
# human and the work itself is what a cycle is for.
labels_ensure() {
  local repo="$1" gh_bin="${LABELS_GH:-gh}"
  [[ -n "$repo" ]] || return 1

  local existing name colour description
  existing="$("$gh_bin" api "repos/$repo/labels" --paginate --jq '.[].name' 2>/dev/null)" \
    || return 1

  while IFS=$'\t' read -r name colour description; do
    [[ -n "$name" ]] || continue
    # GitHub treats label names case-insensitively for uniqueness, so a
    # case-sensitive comparison here would try to create a duplicate and be
    # refused — reported as a failure that is really a success.
    grep -qixF -- "$name" <<<"$existing" && continue
    if "$gh_bin" api -X POST "repos/$repo/labels" \
         -f "name=$name" -f "color=$colour" -f "description=$description" \
         >/dev/null 2>&1; then
      printf 'created\t%s\n' "$name"
    elif "$gh_bin" api "repos/$repo/labels" --paginate --jq '.[].name' 2>/dev/null \
         | grep -qixF -- "$name"; then
      # Another node created it between the listing above and this attempt.
      # Several nodes run the same cycle against the same repositories, so this
      # race is ordinary rather than exceptional, and it is not a failure.
      :
    else
      printf 'failed\t%s\n' "$name"
    fi
  done

  return 0
}

# labels_ensure_role CONFIG_FILE SCHEMA_FILE REPO ROLE [REVIEW_PR_LABEL]
# The two above, together: what a repository in ROLE needs, ensured in REPO.
# REVIEW_PR_LABEL is passed straight through to labels_catalogue; see its
# comment for why ROLE "review" needs it.
labels_ensure_role() {
  local config_file="$1" schema_file="$2" repo="$3" role="$4" review_pr_label="${5:-}"
  labels_catalogue "$config_file" "$schema_file" "$role" "$review_pr_label" | labels_ensure "$repo"
}
