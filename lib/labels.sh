#!/usr/bin/env bash
#
# lib/labels.sh — the pipeline creates its own labels at the point of use, in
# every repository it gathers data for, rather than requiring a human to
# create them first or only reaching a repository once it is selected to work.
#
# Every label this system applies is one an operator had to create by hand, in
# every target repository, before it would do anything. Nothing failed loudly
# when they had not: `refinement_label_add` swallows the error and records the
# block anyway, `create_escalation_issue` retries without the label, and the
# item goes on being handled while the *signal to the human* — the thing the
# label exists to be — silently does not appear. Poetic's own installation had
# drifted exactly that way by August 2026: three of its repositories were
# missing between one and four of the labels the pipeline projects onto their
# items, and no cycle had ever said so — worse in a repository the pipeline
# had not yet selected work in, which got no ensure at all until it did
# (agent-ops#687).
#
# That is a product bug rather than a Poetic quirk (the customer-zero rule in
# docs/ROADMAP.md): a new installation should not need a checklist of `gh label
# create` commands to be functional, and a label a human deletes should come
# back on its own. So the Script ensures its labels exist in every repository
# it gathers data for, not only the one it goes on to work — one cheap listing
# per repository per `labels_ensure_interval_hours` (default 24h, a per-repo
# stamp file under `state_dir`), and a create only for what is genuinely
# absent.
#
# Three properties are deliberate:
#
#   - **It only ever creates.** A label that already exists is left exactly as
#     it is, whatever its colour or description. Operators recolour and
#     re-describe labels, and a pipeline that reasserted its own idea of them
#     every cycle would be undoing that work on a schedule.
#   - **It can never fail a cycle.** A repository this cannot list, or a token
#     without permission to create, yields a report and nothing else. The
#     tolerances the callers already carry stay exactly where they are: this
#     makes the common case work, it does not become a new thing that breaks.
#   - **It is periodic, not once-forever.** A repository already fully
#     labelled costs a stat against its stamp file, not a listing — but the
#     check repeats every interval rather than stopping after the first
#     success, which is what keeps "a label a human deletes comes back on its
#     own" true for as long as the repository is configured.
#
# `labels_ensure_one` is the single-label primitive `refinement_label_add`
# (lib/refinement.sh) self-heals through when a projection's add fails: the
# ensure above is periodic, not synchronous with every write, so a projection
# can still race a repository whose stamp has not been refreshed yet.
#
# `labels_reconcile`/`labels_reconcile_role` give the three properties above
# up for any label named under `label_prefix` (config.schema.json, default
# `pw::`): create, reconcile colour/description drift, and delete once no
# longer catalogued — full ownership of that namespace, never touching a
# label outside it. No call site uses them yet; renaming the catalogue below
# to `pw::`-prefixed names and wiring `labels_ensure_role`'s own call sites
# onto `labels_reconcile_role` is TD-PPagop-26082809.
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
               "Raised by the Enabler: a blocked item that escalates"),
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
               "Hand-applied to say a still-open, diff-carrying draft PR is unwanted; no pipeline stage applies this"),
         entry("open-question"; "d4c5f9";
               "Reviewer-projected: an open scope question blocks unattended landing until adjudicated (D18 #668)"),
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
               "Raised by the Enabler: a blocked item that escalates") ]
     else [] end)
    | .[] | @tsv
  ' <<<"$defaulted" 2>/dev/null || true
}

# _labels_create_one GH_BIN REPO NAME COLOUR DESCRIPTION
# Internal: attempt one create, and on refusal re-list to tell a peer node's
# race (created moments ago, not a failure) apart from a genuine failure.
# Prints `created`, `present` or `failed` and returns 0 for the first two.
# Shared by labels_ensure's batch loop and labels_ensure_one's single-name
# path so this create-then-recheck logic lives in exactly one place.
_labels_create_one() {
  local gh_bin="$1" repo="$2" name="$3" colour="$4" description="$5"
  if "$gh_bin" api -X POST "repos/$repo/labels" \
       -f "name=$name" -f "color=$colour" -f "description=$description" \
       >/dev/null 2>&1; then
    printf 'created'
    return 0
  elif "$gh_bin" api "repos/$repo/labels" --paginate --jq '.[].name' 2>/dev/null \
       | grep -qixF -- "$name"; then
    # Another node created it between the listing above and this attempt.
    # Several nodes run the same cycle against the same repositories, so this
    # race is ordinary rather than exceptional, and it is not a failure.
    printf 'present'
    return 0
  else
    printf 'failed'
    return 1
  fi
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
    case "$(_labels_create_one "$gh_bin" "$repo" "$name" "$colour" "$description")" in
      created) printf 'created\t%s\n' "$name" ;;
      failed)  printf 'failed\t%s\n' "$name" ;;
    esac
  done

  return 0
}

# labels_ensure_one REPO NAME [COLOUR] [DESCRIPTION]
# Create NAME in REPO iff it is not already there. Prints `created`, `present`
# or `failed` — no trailing name, since the caller names exactly one label
# already — on labels_ensure's own three properties: create-only, never
# fatal to the caller (a repository this cannot list still returns 1
# advisory, same as labels_ensure), and race-tolerant.
#
# COLOUR/DESCRIPTION default to a neutral grey and no description, for a
# caller that just wants *a* label to exist. When NAME is a catalogue member,
# pass its catalogue colour/description (from labels_catalogue) instead, so a
# label created lazily this way is indistinguishable from one the ordinary
# eager `labels_ensure_role` path would have created.
labels_ensure_one() {
  local repo="$1" name="$2" colour="${3:-ededed}" description="${4:-}" \
    gh_bin="${LABELS_GH:-gh}"
  [[ -n "$repo" && -n "$name" ]] || return 1

  local existing
  existing="$("$gh_bin" api "repos/$repo/labels" --paginate --jq '.[].name' 2>/dev/null)" \
    || { printf 'failed'; return 1; }
  if grep -qixF -- "$name" <<<"$existing"; then
    printf 'present'
    return 0
  fi
  _labels_create_one "$gh_bin" "$repo" "$name" "$colour" "$description"
}

# labels_ensure_role CONFIG_FILE SCHEMA_FILE REPO ROLE [REVIEW_PR_LABEL]
# The two above, together: what a repository in ROLE needs, ensured in REPO.
# REVIEW_PR_LABEL is passed straight through to labels_catalogue; see its
# comment for why ROLE "review" needs it.
labels_ensure_role() {
  local config_file="$1" schema_file="$2" repo="$3" role="$4" review_pr_label="${5:-}"
  labels_catalogue "$config_file" "$schema_file" "$role" "$review_pr_label" | labels_ensure "$repo"
}

# _labels_urlencode NAME
# Internal: percent-encode NAME for use as a path segment in a GitHub API
# URL — a label name may carry `:` or `/`, and the label-specific endpoints
# (`.../labels/{name}`) address one label by name in the path rather than in
# a form field, unlike the create endpoint above.
_labels_urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

# _labels_find NAME < EXISTING
# Internal: EXISTING is `name<TAB>colour<TAB>description` lines, as
# `labels_reconcile`'s own listing produces. Print NAME's existing
# `colour<TAB>description` and return 0 if EXISTING carries it
# (case-insensitively, matching GitHub's own label-name comparison), return 1
# with nothing printed otherwise.
_labels_find() {
  local name="$1" e_name e_colour e_desc
  while IFS=$'\t' read -r e_name e_colour e_desc; do
    [[ -n "$e_name" ]] || continue
    if [[ "${e_name,,}" == "${name,,}" ]]; then
      printf '%s\t%s\n' "$e_colour" "$e_desc"
      return 0
    fi
  done
  return 1
}

# _labels_update_one GH_BIN REPO NAME COLOUR DESCRIPTION
# Internal: PATCH an existing label's colour/description. Prints `updated`
# and returns 0 on success, `failed` and returns 1 otherwise. Never touches
# NAME itself — reconciling colour/description drift is this file's whole
# CRUD story for now; renaming a label is the follow-on item requirement 6a's
# comment on `labels_reconcile` names.
_labels_update_one() {
  local gh_bin="$1" repo="$2" name="$3" colour="$4" description="$5" encoded
  encoded="$(_labels_urlencode "$name")"
  if "$gh_bin" api -X PATCH "repos/$repo/labels/$encoded" \
       -f "color=$colour" -f "description=$description" \
       >/dev/null 2>&1; then
    printf 'updated'
    return 0
  fi
  printf 'failed'
  return 1
}

# _labels_delete_one GH_BIN REPO NAME
# Internal: DELETE an existing label. Prints `deleted` and returns 0 on
# success, `failed` and returns 1 otherwise.
_labels_delete_one() {
  local gh_bin="$1" repo="$2" name="$3" encoded
  encoded="$(_labels_urlencode "$name")"
  if "$gh_bin" api -X DELETE "repos/$repo/labels/$encoded" >/dev/null 2>&1; then
    printf 'deleted'
    return 0
  fi
  printf 'failed'
  return 1
}

# labels_reconcile REPO PREFIX MODE < CATALOGUE
# labels_ensure's own create-only, never-touch treatment for every catalogue
# entry whose name does not start with PREFIX (case-insensitively) — full
# CRUD for every entry that does: create if absent, PATCH colour/description
# on drift, and, when MODE is `full`, DELETE any existing PREFIX-named label
# in REPO that CATALOGUE no longer names. MODE `additive` does the
# create/update half only and never deletes — for a caller whose CATALOGUE is
# a partial subset of everything PREFIX owns in REPO: a delete scoped to a
# subset would remove another caller's still-wanted labels, which is exactly
# why `labels_reconcile_role` below only ever passes `full` for its `target`
# role, the one catalogue call that is a repository's complete desired set.
# PREFIX empty routes every entry through the create-only path: reconciling
# and deleting are opt-in, never a change to the existing safety property
# that an operator's own label is never touched.
#
# Prints one `created`, `updated`, `deleted` or `failed`<TAB>name line per
# label acted on; nothing for a label already matching its catalogue entry —
# labels_ensure's own silence in the steady state, extended to cover
# "colour/description already match" as well as "already present". Returns 0
# whenever REPO's labels could be listed, 1 when they could not — the same
# advisory-only contract as labels_ensure; never fatal to a caller.
labels_reconcile() {
  local repo="$1" prefix="${2:-}" mode="${3:-full}" gh_bin="${LABELS_GH:-gh}"
  [[ -n "$repo" ]] || return 1

  local catalogue existing
  catalogue="$(cat)"
  existing="$("$gh_bin" api "repos/$repo/labels" --paginate --jq \
    '.[] | [.name, .color, (.description // "")] | @tsv' 2>/dev/null)" \
    || return 1

  local name colour description desired_prefixed=()
  while IFS=$'\t' read -r name colour description; do
    [[ -n "$name" ]] || continue

    if [[ -n "$prefix" && "${name,,}" == "${prefix,,}"* ]]; then
      desired_prefixed+=("$name")
      local existing_colour_desc
      if existing_colour_desc="$(_labels_find "$name" <<<"$existing")"; then
        local existing_colour existing_desc
        existing_colour="$(cut -f1 <<<"$existing_colour_desc")"
        existing_desc="$(cut -f2 <<<"$existing_colour_desc")"
        if [[ "$existing_colour" != "$colour" || "$existing_desc" != "$description" ]]; then
          if _labels_update_one "$gh_bin" "$repo" "$name" "$colour" "$description" >/dev/null; then
            printf 'updated\t%s\n' "$name"
          else
            printf 'failed\t%s\n' "$name"
          fi
        fi
      else
        case "$(_labels_create_one "$gh_bin" "$repo" "$name" "$colour" "$description")" in
          created) printf 'created\t%s\n' "$name" ;;
          failed)  printf 'failed\t%s\n' "$name" ;;
        esac
      fi
    else
      _labels_find "$name" <<<"$existing" >/dev/null && continue
      case "$(_labels_create_one "$gh_bin" "$repo" "$name" "$colour" "$description")" in
        created) printf 'created\t%s\n' "$name" ;;
        failed)  printf 'failed\t%s\n' "$name" ;;
      esac
    fi
  done <<<"$catalogue"

  if [[ -n "$prefix" && "$mode" == "full" ]]; then
    local existing_name existing_colour existing_desc
    while IFS=$'\t' read -r existing_name existing_colour existing_desc; do
      [[ -n "$existing_name" ]] || continue
      [[ "${existing_name,,}" == "${prefix,,}"* ]] || continue
      local kept=0 d
      for d in ${desired_prefixed[@]+"${desired_prefixed[@]}"}; do
        [[ "${d,,}" == "${existing_name,,}" ]] && { kept=1; break; }
      done
      if [[ "$kept" -eq 0 ]]; then
        if _labels_delete_one "$gh_bin" "$repo" "$existing_name" >/dev/null; then
          printf 'deleted\t%s\n' "$existing_name"
        else
          printf 'failed\t%s\n' "$existing_name"
        fi
      fi
    done <<<"$existing"
  fi

  return 0
}

# labels_reconcile_role CONFIG_FILE SCHEMA_FILE REPO ROLE [REVIEW_PR_LABEL]
# labels_ensure_role's own shape, but through labels_reconcile: reads
# `label_prefix` from CONFIG_FILE/SCHEMA_FILE's merge and reconciles ROLE's
# catalogue against it, MODE derived from ROLE — `full` for `target`, the one
# catalogue call that is a repository's complete desired label set;
# `additive` for every other role, each a partial subset of `target`'s own
# catalogue whose own deletion pass would remove labels `target` still wants
# (labels_reconcile's own comment above). A CONFIG_FILE/SCHEMA_FILE that
# cannot be read leaves PREFIX empty, the same safe fallback
# labels_reconcile's own empty-PREFIX path gives every other caller: nothing
# is reconciled or deleted, only ever created.
labels_reconcile_role() {
  local config_file="$1" schema_file="$2" repo="$3" role="$4" review_pr_label="${5:-}"
  local defaulted prefix=""
  defaulted="$(config_defaults "$config_file" "$schema_file" 2>/dev/null)" \
    && prefix="$(jq -r '.label_prefix // ""' <<<"$defaulted" 2>/dev/null)"
  local mode="additive"
  [[ "$role" == "target" ]] && mode="full"
  labels_catalogue "$config_file" "$schema_file" "$role" "$review_pr_label" \
    | labels_reconcile "$repo" "$prefix" "$mode"
}

# labels_ensure_stamped STATE_DIR CONFIG_FILE SCHEMA_FILE REPO ROLE \
#                       INTERVAL_HOURS [REVIEW_PR_LABEL]
# The rate-limited wrapper around labels_ensure_role (requirement 6a,
# agent-ops#687): ensures ROLE's catalogue in REPO at most once per
# INTERVAL_HOURS, so a repository this system has already labelled costs
# nothing beyond a stat(2) once the first listing has run. Keyed per
# (REPO, ROLE) via its own stamp file under STATE_DIR/labels-ensured/, so one
# repository's — or one role's — interval elapsing says nothing about
# another's. Deliberately periodic rather than once-forever: requirement 6a's
# own promise is that a label a human deletes comes back on its own, and that
# only stays true if the check repeats.
#
# The stamp is touched only after a listing actually succeeds: a repository
# whose labels could not be listed (labels_ensure_role's own advisory
# failure, propagated here) leaves no stamp, so the very next cycle tries
# again rather than waiting out a whole interval on a failure this never
# actually paid for.
#
# INTERVAL_HOURS <= 0, or unset/non-numeric, disables the stamp check
# entirely: every call ensures. It is read as whole hours, from the value's
# integer part — see the truncation below for why a decimal reaches here at
# all. Prints labels_ensure_role's own report
# (nothing, on a skipped call) and returns its exit status (0 on a skipped
# call — a rate-limited repeat is success, not a failure to check).
labels_ensure_stamped() {
  local state_dir="$1" config_file="$2" schema_file="$3" repo="$4" role="$5" \
    interval_hours="${6:-24}" review_pr_label="${7:-}"
  [[ -n "$state_dir" && -n "$repo" && -n "$role" ]] || return 1

  local stamp_dir="$state_dir/labels-ensured" safe="${repo//\//_}"
  local stamp_file="$stamp_dir/$safe.$role"
  # Compared as whole hours, taken from the value's integer part. `24.0` is a
  # schema-valid `integer` — JSON Schema counts a zero fraction as one, and jq
  # preserves the literal it read — so the interval can arrive here as a
  # decimal string, which an integer-only test would reject outright and so
  # disable the rate limit rather than apply it: the opposite of what the
  # operator asked for, silently. Truncating first means a fraction can only
  # ever shorten the interval (`0.5` -> `0`, ensure on every call), never
  # remove it.
  local whole_hours="${interval_hours%%.*}"
  if [[ "$whole_hours" =~ ^[0-9]+$ ]] && (( whole_hours > 0 )) \
       && [[ -f "$stamp_file" ]]; then
    local mtime age
    mtime="$(stat -c %Y "$stamp_file" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - mtime ))
    (( age < whole_hours * 3600 )) && return 0
  fi

  local report rc=0
  report="$(labels_ensure_role "$config_file" "$schema_file" "$repo" "$role" "$review_pr_label")" \
    || rc=$?
  if (( rc == 0 )); then
    mkdir -p "$stamp_dir" 2>/dev/null \
      && : > "$stamp_file.tmp.$$" 2>/dev/null \
      && mv "$stamp_file.tmp.$$" "$stamp_file" 2>/dev/null
  fi
  printf '%s' "$report"
  return "$rc"
}
