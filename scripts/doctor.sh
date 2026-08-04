#!/usr/bin/env bash
#
# doctor.sh — check an installation end to end, before it runs a cycle.
#
# Everything this system needs to work sits in three places: the
# configuration, the toolchain around it, and the GitHub access it is granted.
# Each fails differently and none of them fails clearly. A misconfigured key is
# silent by construction — an unread key is a default nobody chose; a missing
# tool surfaces an hour later as a stage that died mid-cycle, after the work
# was already claimed; a token missing a scope shows up as an empty work
# source, which looks exactly like a repository with no work in it. The checks
# below are chosen for that: each one is a failure that otherwise costs a
# cycle, or a night, to notice.
#
# Read-only, with two exceptions it declares: it creates the state and
# workspace directories the configuration already names, because being able to
# create them is the thing being checked, and it renders a trial crontab into
# a `mktemp -d` it removes afterwards, to prove the template and the schedule
# in the config actually produce one. Every GitHub call is a GET. Safe to run
# against a live node at any time, including while a cycle holds the lock.
#
# Three verdicts, and a fourth for what it could not reach:
#
#   fail — the pipeline will not work, or will work on something other than
#          what the configuration says. Exit status 1.
#   warn — it will work, but something here will surprise the operator later.
#   skip — the check needs something unavailable right now (the network, an
#          authenticated `gh`, a usable `claude` credential), so it is
#          neither passed nor failed.
#
# Run it after editing config.json, on a new node before its first cycle, and
# whenever a cycle does something the configuration does not explain:
#
#   scripts/doctor.sh                 # this installation
#   scripts/doctor.sh --offline       # everything but GitHub access and the two Claude checks
#   scripts/doctor.sh --config PATH   # a config not yet deployed
#
# Exit: 0 clean (warnings and skips included) · 1 at least one failure ·
#       2 the arguments or the config file itself were unusable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
source "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/model-id.sh
source "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/labels.sh
source "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/fleet.sh
source "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/stage-budget.sh
source "$SCRIPT_DIR/lib/stage-budget.sh"

usage() {
  cat >&2 <<'USAGE'
usage: doctor.sh [--config PATH] [--offline] [--quiet]

Check this installation end to end: the configuration against
config.schema.json, the toolchain the pipelines need, the directories they
write to, the rendered crontab, the GitHub access they are granted, the
Claude credentials the stages run as, and whether a stage's event stream
really flushes as it runs on this node.

  --config PATH  Check this file instead of the repository's config.json.
  --offline      Skip every check that needs the network (GitHub access, the
                 Claude credentials, the stream-flushing probe); report them
                 skipped. The probe is the one check here that spends: a
                 single call to the cheapest configured model.
  --quiet        Print only warnings, failures and the summary.

Exit 0 clean, 1 at least one failure, 2 unusable arguments or config.
USAGE
}

config_file="$SCRIPT_DIR/config.json"
schema_file="$SCRIPT_DIR/config.schema.json"
offline=0
quiet=0
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --config)
      [[ $# -ge 2 ]] || { echo "doctor: --config needs a path" >&2; exit 2; }
      config_file="$2"; shift 2 ;;
    --offline) offline=1; shift ;;
    --quiet) quiet=1; shift ;;
    *) echo "doctor: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

fails=0
warns=0
skips=0
pending_section=""

# A section heading is held back until something under it prints, so --quiet
# never leaves a heading with nothing beneath it.
section() { pending_section="$1"; }
show_section() {
  [[ -n "$pending_section" ]] || return 0
  printf '\n%s\n' "$pending_section"
  pending_section=""
}
ok()   { ((quiet)) || { show_section; printf '  [ ok ] %s\n' "$1"; }; }
warn() { warns=$((warns + 1)); show_section; printf '  [warn] %s\n' "$1"; }
fail() { fails=$((fails + 1)); show_section; printf '  [fail] %s\n' "$1"; }
skip() { skips=$((skips + 1)); ((quiet)) || { show_section; printf '  [skip] %s\n' "$1"; }; }

# --- Configuration ---

section "Configuration ($config_file)"

if [[ ! -r "$config_file" ]]; then
  show_section
  printf '  [fail] cannot read %s\n' "$config_file"
  printf '\nUnusable configuration — nothing further can be checked.\n'
  exit 2
fi
if ! jq -e . "$config_file" >/dev/null 2>&1; then
  show_section
  printf '  [fail] %s is not valid JSON\n' "$config_file"
  jq . "$config_file" 2>&1 | sed 's/^/         /'
  printf '\nUnusable configuration — nothing further can be checked.\n'
  exit 2
fi

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below. It performs no validation of its own — a config that fails the
# schema gate below still merges cleanly, which is what lets every check past
# that point keep running against something rather than stopping at the first
# fault. Its stderr is discarded because the one thing that silences it is an
# unreadable schema, and that is the very condition the schema check below
# reports as a `warn` in this command's own vocabulary; letting jq's raw
# diagnostic out here would print it ahead of the report and outside it.
DEFAULTED_CONFIG="$(config_defaults "$config_file" "$schema_file" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }
cfg_json() { jq -c "$1" <<<"$DEFAULTED_CONFIG"; }

schema_errors="$(config_schema_errors "$config_file" "$schema_file")"
case "$?" in
  0) ok "matches config.schema.json" ;;
  1) while IFS= read -r line; do fail "$line"; done <<<"$schema_errors" ;;
  *) warn "$schema_errors — the schema check did not run" ;;
esac

# The rules below are the ones the schema cannot state, because each holds
# between two keys rather than about one. A `fail` here mirrors a startup guard
# in agent-cycle.sh — the cycle would refuse to run; a `warn` is a combination
# that works and then surprises someone.

enabler_model="$(cfg '.enabler_model')"
enabler_assignee="$(cfg '.enabler_assignee')"
if ! config_enabler_assignee_ok "$enabler_model" "$enabler_assignee"; then
  fail "enabler_model is set but enabler_assignee is not — agent-cycle.sh refuses to start rather than raise an escalation that, being unassigned, the pipeline could then select as its own work"
elif [[ -n "$enabler_model" ]]; then
  ok "the Enabler is enabled; its escalations are assigned to @$enabler_assignee"
else
  ok "the Enabler is disabled (enabler_model is empty)"
fi

missing_plan_path="$(config_missing_plan_path_repos "$(cfg_json '.repos // []')")"
if [[ -n "$missing_plan_path" ]]; then
  fail "repo(s) [$missing_plan_path] list the implementation-plan source with no implementation_plan_path — agent-cycle.sh refuses to start, since that source has no path of its own outside the config"
else
  ok "every repo listing implementation-plan names its plan document"
fi

# `blocked` excludes an issue from the issues source, so projecting it onto an
# item would leave that item permanently unselectable — the one value these
# label keys must never take.
for key in enabler_escalation_label needs_refinement_label unvoid_label; do
  if [[ "$(cfg ".$key")" == "blocked" ]]; then
    fail "$key is \"blocked\", which excludes an issue from the issues source — an item carrying it could never be selected again"
  fi
done

excluded_count="$(cfg_json '.schedule.excluded_minutes' \
  | jq 'map(select(type == "number" and . >= 0 and . <= 59)) | unique | length')"
if ((excluded_count >= 60)); then
  fail "schedule.excluded_minutes excludes every minute of the hour — deploy/docker/render-crontab.sh has no minute left to choose"
elif ((excluded_count > 0)); then
  ok "schedule.excluded_minutes leaves $((60 - excluded_count)) minute(s) for this node's cycle"
fi

if [[ "$(cfg '.review.pr_label // ""')" == "$(cfg '.pr_label // ""')" ]]; then
  warn "review.pr_label equals pr_label — review pull requests would count against max_open_agent_prs and be indistinguishable from implementation ones"
fi

# cycles_retained and state_local_cycles_retained both carry real schema
# defaults (200, 1000); the `0` here is pure arithmetic safety against a
# config that failed validation above and reached here with a non-numeric
# value, not a restatement of either default.
read -r cycles_retained local_retained < <(jq -r '
  def num($v): if ($v | type) == "number" then ($v | floor) else 0 end;
  [num(.cycles_retained), num(.state_local_cycles_retained)] | @tsv' <<<"$DEFAULTED_CONFIG")
if ((local_retained < cycles_retained)); then
  warn "state_local_cycles_retained ($local_retained) is below cycles_retained ($cycles_retained) — the replicated mirror would hold a longer history than the node that writes it"
fi

if [[ "$(cfg '.crash_loop_after')" != "0" && -z "$(cfg '.crash_loop_repo')" ]]; then
  warn "crash_loop_after is set but crash_loop_repo is empty, which disables the check anyway — a fleet-wide Co-Ordinator crash loop would surface nowhere"
fi

# --- Models ---

section "Models"

while IFS=$'\t' read -r key value; do
  [[ -n "$key" ]] || continue
  if resolved="$(resolve_model_id "$key" "$value" 2>&1)"; then
    ok "$key → $resolved"
  else
    fail "$resolved"
  fi
done < <(jq -r '
  [ {k: "coordinator_model",          v: .coordinator_model},
    {k: "implementor_model_default",  v: .implementor_model_default},
    {k: "implementor_model_trivial",  v: .implementor_model_trivial},
    {k: "reviewer_model_default",     v: .reviewer_model_default},
    {k: "reviewer_model_complex",     v: .reviewer_model_complex},
    {k: "enabler_model",              v: .enabler_model},
    {k: "review.model",               v: .review.model}
  ] | .[] | select((.v // "") != "") | [.k, .v] | @tsv' "$config_file")

# --- Prompts ---

section "Prompts"

state_dir="$(cfg '.state_dir')"
[[ "$state_dir" == "~"* ]] && state_dir="$HOME${state_dir:1}"

missing_prompt=0
for prompt in coordinator implementor reviewer enabler project-reviewer; do
  if [[ ! -r "$SCRIPT_DIR/prompts/$prompt.md" ]]; then
    fail "prompts/$prompt.md is missing or unreadable"
    missing_prompt=1
  fi
done
((missing_prompt)) || ok "every shipped prompt is present"

# A configured override path that does not resolve is tolerated at runtime —
# files legitimately come and go — which is exactly why it is worth naming
# here: the stage quietly runs on the shipped prompt instead.
while IFS=$'\t' read -r stage mode path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    "~"*) resolved_path="$HOME${path:1}" ;;
    /*) resolved_path="$path" ;;
    *) resolved_path="$state_dir/$path" ;;
  esac
  if [[ -r "$resolved_path" ]]; then
    ok "prompt_overrides.$stage.$mode → $resolved_path"
  else
    warn "prompt_overrides.$stage.$mode names $resolved_path, which is not readable — the $stage stage runs on the shipped prompt and says nothing about it"
  fi
done < <(cfg_json '.prompt_overrides' | jq -r '
  to_entries[]
  | .key as $stage
  | ((.value.extend // [])[] | [$stage, "extend", .] | @tsv),
    (select((.value.replace // "") != "") | [$stage, "replace", .value.replace] | @tsv)')

# --- Toolchain ---

section "Toolchain"

# The pipelines' hard requirements, as deploy/docker/Dockerfile installs them.
# Without any one of these a cycle dies part-way through, having already
# claimed its work — which is the expensive way to discover it.
for tool in bash jq git curl perl python3 rsync flock timeout; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool — $(command -v "$tool")"
  else
    fail "$tool is not on PATH; the pipelines need it"
  fi
done
if command -v gh >/dev/null 2>&1; then
  ok "gh — $(gh --version 2>/dev/null | head -1)"
else
  fail "gh is not on PATH; every work source and every pull request goes through it"
fi
if command -v claude >/dev/null 2>&1; then
  ok "claude — $(claude --version 2>/dev/null | head -1)"
else
  fail "claude is not on PATH; it is the execution substrate for every stage"
fi
if command -v shellcheck >/dev/null 2>&1; then
  ok "shellcheck — $(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')"
else
  warn "shellcheck is not on PATH — an Implementor working on shell cannot lint before it pushes"
fi

# --- Directories ---

section "Directories"

workspace_root="$(cfg '.workspace_root')"
[[ "$workspace_root" == "~"* ]] && workspace_root="$HOME${workspace_root:1}"
for entry in "state_dir=$state_dir" "workspace_root=$workspace_root"; do
  key="${entry%%=*}"
  dir="${entry#*=}"
  if [[ -z "$dir" || "$dir" == "null" ]]; then
    fail "$key is not set"
  elif mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]] && ((avail_kb < 2 * 1024 * 1024)); then
      warn "$key ($dir) is writable but has only $((avail_kb / 1024)) MiB free — a cycle clones every repository it touches"
    else
      ok "$key ($dir) is writable"
    fi
  else
    fail "$key ($dir) cannot be created or is not writable"
  fi
done

# --- Crontab ---

section "Stage budgets"

# --- The stage budgets, and the lock derived from them (requirement 4f) --------
# This check used to be an assertion — that `lock_stale_after` exceeded the sum
# of four fixed stage timeouts — and it was warned about, adjusted by hand and
# warned about again three times in two days while those timeouts were being
# raised. The invariant is now inverted: the lock threshold is *derived* from
# the backstops in force plus slack, so it cannot be outrun, and what is left
# to report is what those numbers currently are and where each came from.
#
# Reported rather than merely computed, because that is the whole bargain of a
# self-tuning value: it is allowed to move on its own precisely because it can
# always be asked what it is and why.
budget_table="$(stage_budget_table \
  "$(fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
     | stage_budget_observations 2>/dev/null || printf '[]')" \
  "$(stage_budget_settings "$(cat "$config_file" 2>/dev/null || printf '{}')")" \
  2>/dev/null || printf '{"cells":{},"actors":{}}')"

lock_stale_sec="$(stage_budget_lock_seconds "$budget_table" \
  "$(jq -c '["coordinator","implementor","reviewer","enabler"]
            | map(. as $a | {key: $a, value: {backstop: (.["timeout_" + $a] // null)}})
            | from_entries' <<<"$(cat "$config_file")" 2>/dev/null || printf '{}')" \
  30 "$(jq -r '.lock_stale_after // 0' "$config_file" 2>/dev/null || printf 0)")"
ok "the cycle lock is derived at $(( lock_stale_sec / 60 )) min, from the backstops in force plus 30 min slack"

cell_count="$(jq -r '(.cells // {}) | length' <<<"$budget_table" 2>/dev/null || printf 0)"
if [[ "$cell_count" =~ ^[0-9]+$ ]] && (( cell_count > 0 )); then
  while IFS=$'\t' read -r cell backstop inactivity basis n; do
    [[ -n "$cell" ]] || continue
    ok "$cell: backstop ${backstop} min, watchdog ${inactivity} min (${basis}, n=${n})"
  done < <(jq -r '(.cells // {}) | to_entries | sort_by(.key)[]
                  | [.key, (.value.backstop_min|tostring), (.value.inactivity_min|tostring),
                     .value.basis, (.value.n|tostring)] | @tsv' <<<"$budget_table" 2>/dev/null || true)
else
  ok "no stage history yet — every stage runs on its shipped prior, which is what a first cycle should do"
fi

# A configured cap is an override that outranks the derivation for as long as
# it is there, which is easy to set once and then forget about entirely.
while IFS= read -r overridden; do
  [[ -n "$overridden" ]] || continue
  warn "$overridden is set, which pins that cap and turns off its self-tuning — remove it unless you mean to"
done < <(jq -r '[ "timeout_coordinator", "timeout_implementor", "timeout_reviewer",
                  "timeout_enabler", "inactivity_coordinator", "inactivity_implementor",
                  "inactivity_reviewer", "inactivity_enabler" ]
                | map(select(. as $k | ($ARGS.named.cfg[$k] | type) == "number"))[]' \
              --argjson cfg "$(cat "$config_file")" -n 2>/dev/null || true)
section "Crontab"

render_script="$SCRIPT_DIR/deploy/docker/render-crontab.sh"
tmpl_file="$SCRIPT_DIR/deploy/docker/crontab.tmpl"
if [[ ! -r "$tmpl_file" ]]; then
  skip "deploy/docker/crontab.tmpl is missing — cannot render the schedule"
else
  crontab_tmp_dir="$(mktemp -d)"
  node_name="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
  if render_out="$(NODE_NAME="$node_name" "$render_script" "$tmpl_file" "$crontab_tmp_dir/crontab" "$config_file" 2>&1)"; then
    render_summary="${render_out##*$'\n'}"
    render_summary="${render_summary#*: }"
    if [[ -n "${CYCLE_MINUTE:-}" && "$render_out" != *"is not an allowed minute"* ]]; then
      minute_note="cycle minute set explicitly by CYCLE_MINUTE=$CYCLE_MINUTE"
    else
      minute_note="cycle minute hashed from node name $node_name"
    fi
    heartbeat_minutes="$(cfg '.schedule.heartbeat_minutes // 5')"
    ok "${render_summary} — heartbeat every ${heartbeat_minutes} min ($minute_note)"
    push_minutes="$(cfg '.schedule.state_sync_push_minutes // 5')"
    fetch_minutes="$(cfg '.schedule.state_sync_fetch_minutes // 7')"
    rotation_minute="$(cfg '.schedule.log_rotation_minute // 19')"
    ok "background timers — state sync push every ${push_minutes} min, fetch every ${fetch_minutes} min, log rotation at :${rotation_minute}"
  else
    fail "deploy/docker/render-crontab.sh failed against $config_file: ${render_out:-no output}"
  fi
  rm -rf "$crontab_tmp_dir"
fi

# --- Repository priority ---

section "Repository priority"

# Silent when every repo sits at nice 0 — this is a report of what the config
# already asks for (lib/repo-order.sh's `effective_age = age × 1.25^(-nice)`),
# not a check with a right answer, so there is nothing to warn or fail on.
while IFS=$'\t' read -r slug nice weight; do
  [[ -n "$slug" ]] || continue
  if [[ "$nice" == -* ]]; then
    ok "$slug: nice $nice — effective age ×$weight, earlier attention"
  else
    ok "$slug: nice $nice — effective age ×$weight, later attention"
  fi
done < <(jq -r '
  (.repos // [])[]
  | select((.nice // 0) != 0)
  | (.nice // 0) as $n
  | [.slug, ($n | tostring), (pow(1.25; -$n) * 100 | round / 100 | tostring)]
  | @tsv
' "$config_file")

# --- GitHub ---

section "GitHub"

gh_ready=0
if ((offline)); then
  skip "every GitHub check (--offline)"
elif ! command -v gh >/dev/null 2>&1; then
  skip "every GitHub check (gh is not installed)"
elif ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated — run 'gh auth login' or set GH_TOKEN; every work source reads through it"
else
  gh_ready=1
  ok "gh is authenticated as $(gh api user --jq .login 2>/dev/null || echo '(login unavailable)')"
fi

if ((gh_ready)); then
  # What each repository should carry comes from lib/labels.sh's catalogue —
  # the same list the cycle creates from — so this cannot report a different
  # set from the one the pipeline actually maintains (requirement 6a).
  # Fetched once per repository rather than once per label: the pipeline wants
  # several, and a repository is either reachable or it is not.
  #
  # A missing label is a warning rather than a failure because the next cycle
  # to work that repository creates it. What is worth saying is that it has not
  # happened yet: on a fresh installation that is simply "no cycle has run
  # here", and on an established one it means the token cannot create labels,
  # which nothing else would tell you.
  check_repo_labels() {
    local slug="$1" role="$2" repo_labels label
    if ! repo_labels="$(gh api "repos/$slug/labels" --paginate --jq '.[].name' 2>/dev/null)"; then
      return 1
    fi
    while IFS=$'\t' read -r label _ _; do
      [[ -n "$label" ]] || continue
      grep -qixF -- "$label" <<<"$repo_labels" \
        || warn "$slug has no \"$label\" label — the next cycle that works this repo creates it (lib/labels.sh); if it is still absent after one has run, this token may not create labels"
    done < <(labels_catalogue "$config_file" "$schema_file" "$role")
    return 0
  }

  # Write access is a separate call from the label read above: a token can
  # list a repository's labels while unable to push to it (fine-grained PATs
  # commonly split read and write this way), and that gap is exactly what
  # costs a cycle its work — it claims an item, implements it, and only then
  # discovers the push fails. `.permissions` is present only on requests
  # `gh` makes as an authenticated user, so an absent field is a fact about
  # what the API told this token, not evidence the token lacks push access —
  # hence `skip`, never `fail`, when it is missing.
  #
  # One helper for every repository's write-access verdict — target, review
  # and state_repo alike — so the three call sites cannot drift apart on what
  # counts as ok/fail/skip, the way a hand-rolled state_repo check once did:
  # its own `push == false || push == null` collapsed both into `fail`,
  # reporting a token that merely can't be asked as one that can't push.
  check_repo_access() {
    local slug="$1" ok_msg="${2:-is writable — the token can push claim branches}" \
          fail_msg="${3:-is readable but not writable with this token — a cycle would claim work here and lose it at push}" \
          unreachable_msg="${4:-is unreachable with this token — cannot confirm write access}" \
          json push archived
    if ! json="$(gh api "repos/$slug" --jq '{push: .permissions.push, archived: (.archived // false)}' 2>/dev/null)"; then
      fail "$slug $unreachable_msg"
      return
    fi
    archived="$(jq -r '.archived' <<<"$json" 2>/dev/null)"
    push="$(jq -r '.push' <<<"$json" 2>/dev/null)"
    if [[ "$archived" == "true" ]]; then
      fail "$slug is archived — no branch can be pushed to it, whatever the token's permissions"
    elif [[ "$push" == "true" ]]; then
      ok "$slug $ok_msg"
    elif [[ "$push" == "false" ]]; then
      fail "$slug $fail_msg"
    else
      skip "$slug's write permission is not visible to this token (no .permissions field) — cannot confirm push access"
    fi
  }

  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    if check_repo_labels "$slug" target; then
      ok "$slug is readable"
    else
      fail "$slug is unreachable with this token — a repository the pipeline cannot read is a work source that silently reports no work"
    fi
    check_repo_access "$slug"
  done < <(cfg '.repos[]?.slug // empty')

  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    check_repo_labels "$slug" review \
      || fail "review.repos names $slug, which is unreachable with this token"
    check_repo_access "$slug"
  done < <(cfg '.review.repos[]? // empty')

  state_repo="$(cfg '.state_repo')"
  if [[ -z "$state_repo" ]]; then
    ok "no state_repo configured — single-node operation, every state-sync mode is a no-op"
  else
    check_repo_access "$state_repo" \
      "is readable and writable — the fleet's shared state can replicate" \
      "is readable but not writable with this token — this node could fetch fleet state and never publish its own" \
      "is unreachable with this token — claims, fleet flags and the shared log would not replicate"
  fi

  if [[ -n "$enabler_assignee" ]]; then
    if gh api "users/$enabler_assignee" --jq .login >/dev/null 2>&1; then
      ok "enabler_assignee @$enabler_assignee is a GitHub account"
    else
      fail "enabler_assignee @$enabler_assignee is not a GitHub account — its escalations would be raised unassigned, and the pipeline could then select them as work"
    fi
  fi
fi

# --- Claude ---

section "Claude"

if ((offline)); then
  skip "Claude credentials (--offline)"
elif ! command -v claude >/dev/null 2>&1; then
  skip "Claude credentials (claude is not installed)"
elif ! claude_auth_json="$(timeout 15 claude auth status --json 2>/dev/null)"; then
  # An older CLI with no `auth` subcommand, or one that hangs and hits the
  # timeout above, exits non-zero here rather than printing anything this
  # can trust — a version gap, not a finding about this token.
  skip "claude auth status did not succeed — cannot verify credentials"
elif ! logged_in="$(jq -r '.loggedIn' <<<"$claude_auth_json" 2>/dev/null)"; then
  # -r without -e: `false` is a legitimate answer this check must tell apart
  # from a parse failure, and -e would treat both alike (its exit status
  # reflects the output *value*, not whether parsing succeeded).
  skip "claude auth status printed something other than the expected JSON — cannot verify credentials"
elif [[ "$logged_in" == "true" ]]; then
  ok "claude is authenticated ($(jq -r '.authMethod // "method unknown"' <<<"$claude_auth_json"), $(jq -r '.subscriptionType // .apiProvider // "provider unknown"' <<<"$claude_auth_json"))"
else
  fail "claude is not authenticated — every stage launches through it and would fail at the first invocation"
fi

# --- The stream really streams, on this node -----------------------------------
# The liveness watchdog (requirement 4e) reads one thing: whether the stage's
# stream file has grown lately. That is only a liveness signal if the runtime
# writes as it goes. If it buffers stdout when the destination is not a tty —
# and the evidence for this design was gathered on one machine and one CLI
# version, so another may differ — the file stays empty until the run ends and
# the watchdog kills every healthy stage at its threshold. There is no partial
# version of that failure: streaming either works on this node or the pipeline
# stops working on this node. So it is checked here, on this node, with a real
# invocation, rather than reasoned about.
#
# The cost is one call to the cheapest configured model with a one-word
# prompt — the same spend requirement 1b's usage-limit probe makes, for the
# same reason: some questions can only be answered by asking. `doctor.sh` is
# operator-invoked rather than per-cycle, and `--offline` skips it.
if ((offline)); then
  skip "stream flushing (--offline; the check costs one minimal model call)"
elif ! command -v claude >/dev/null 2>&1; then
  skip "stream flushing (claude is not installed)"
elif [[ "${logged_in:-}" != "true" ]]; then
  skip "stream flushing (needs a working credential)"
else
  flush_dir="$(mktemp -d)"
  flush_stream="$flush_dir/probe.stream.jsonl"
  claude -p --model "$(cfg '.implementor_model_trivial // "claude-haiku-4-5-20251001"')" \
    --dangerously-skip-permissions --output-format stream-json --verbose \
    <<<"Reply with the single word: ok" >"$flush_stream" 2>"$flush_dir/err" &
  flush_pid=$!
  # Sampled while the invocation is still running, which is the only way to
  # tell "wrote as it went" from "wrote everything at the end" — a finished
  # run looks identical either way.
  flush_seen=0
  flush_waited=0
  while kill -0 "$flush_pid" 2>/dev/null && (( flush_waited < 120 )); do
    if [[ -s "$flush_stream" ]]; then flush_seen=1; break; fi
    sleep 1
    flush_waited=$(( flush_waited + 1 ))
  done
  wait "$flush_pid" 2>/dev/null || true

  if (( flush_seen )); then
    ok "the stage stream flushes as it runs — the liveness watchdog has a signal to read"
  elif [[ ! -s "$flush_stream" ]]; then
    skip "stream flushing: the probe produced nothing at all, so it proves nothing about buffering ($(head -c 160 "$flush_dir/err" 2>/dev/null | tr '\n' ' ' || true))"
  else
    fail "the stage stream arrived only once the invocation had ended — stdout is buffered on this node, so the liveness watchdog would see no progress and kill every healthy stage at its inactivity threshold. Set the inactivity_* keys to 0 to disable the watchdog until this is fixed."
  fi
  rm -rf "$flush_dir"
fi

# --- Summary ---

printf '\n'
if ((fails)); then
  printf '%d failure(s), %d warning(s), %d skipped.\n' "$fails" "$warns" "$skips"
  exit 1
fi
printf 'No failures. %d warning(s), %d skipped.\n' "$warns" "$skips"
exit 0
