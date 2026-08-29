#!/usr/bin/env bash
#
# scripts/check-graphql-drift.sh — validate every GraphQL document this
# repository sends against GitHub's *live* schema (TD-PPagop-26082930).
#
# The gap this closes: every GitHub read in `lib/` is exercised only through a
# `gh` stub this repository writes, and a stub answers in whatever shape its
# own fixture declares. A field GitHub renames, moves or removes therefore
# cannot fail a test — the suite stays green and the only symptom is a stage
# refusing at runtime, in wording that names the gate rather than the cause.
# That is not hypothetical: GitHub moved `mergeMethod` and `mergingStrategy`
# off `MergeQueue` onto `MergeQueue.configuration` between 2026-08-16 and
# 2026-08-23, GraphQL rejects the *whole* document for one unknown field, and
# `lib/merge-queue.sh`'s `merge_queue_for_branch` — which asked for both and
# read neither — returned non-zero on every call for the six days that
# followed. `landing_arm` turned each into its gate-7 refusal, so the fleet's
# first autonomous landing waited on two fields nobody read, while nothing
# failed and nothing alerted.
#
# So this asks GitHub itself, on a schedule, and the answer is only ever as
# current as the last run.
#
# HOW A DOCUMENT IS CHECKED WITHOUT BEING RUN. Two of these documents are
# mutations — `enqueuePullRequest` (lib/landing.sh) and `setIssueFieldValue`
# (lib/issue-priority.sh) — and a checker that ran what it checks would
# enqueue a pull request every night. GraphQL validates a document in full
# *before* executing any of it, so each operation's selection set is wrapped
# in an untyped inline fragment carrying `@skip(if:true)`:
#
#   mutation($id:ID!){ ... @skip(if:true) { enqueuePullRequest(…){ … } } }
#
# Validation still walks every field inside the fragment and still reports an
# unknown one; execution collects no fields at all and answers `{"data":{}}`.
# Verified live, 2026-08-29, against GitHub's own endpoint on all four
# corners: the wrapper leaves a good document clean; an unknown field nested
# inside it is still reported as `undefinedField`; the same mutation *without*
# the wrapper does resolve its argument (`NOT_FOUND` on a bogus node id),
# which is what proves the wrapper is the thing preventing execution; and the
# pre-fix `mergeQueue(branch:$branch){ id mergeMethod mergingStrategy }`
# selection set is reported field by field — this check, had it existed, would
# have failed on 2026-08-23 instead of six days later.
#
# Two rejected alternatives, both tried live first. Sending a bogus
# `operationName` short-circuits before validation ("No operation named …")
# and reports nothing about the document at all — it is the silent pass this
# whole item exists to retire. Putting `@skip` on each top-level field
# directly needs the field's arguments parsed to find where the directive
# goes; wrapping the operation's own selection set needs only its braces
# matched, and covers every top-level field at once rather than the first.
#
# WHAT IT CANNOT CATCH. Validation answers "does this document still mean
# something to the schema", not "does it still mean the same thing": a field
# that kept its name and type while changing what it returns, an argument
# whose default moved, an enum that gained a value. Those stay the runtime's
# problem. It does catch — beyond a removed or moved field — a field that
# gained or lost a selection set, an argument that no longer exists, and a
# variable declared at a type the argument no longer accepts. That last one is
# agent-ops#737 exactly, where `$optionId:String!` against an `ID` argument
# failed every Priority write the fleet attempted; it is reported here as
# `variableMismatch`, and was confirmed so live.
#
# DISCOVERY IS A SEARCH, NEVER A LIST. The documents are found by scanning
# every file in the tree for `-f query='`, the one form all of them use, rather
# than from a list somebody maintains — for the reason
# `.github/workflows/td-tooling-drift.yml` gives about its own manifest: a
# hard-coded list can only cover what someone already thought to add to it, so
# the document added tomorrow is invisible to the very check meant to cover
# it. Finding *none* is therefore a failure, never a quiet pass. `prompts/`
# counts: those documents are sent by the agents this repository operates, and
# `prompts/reviewer.md`'s merge-queue probe guards a push that cannot be
# undone.
#
# Usage:
#   ./scripts/check-graphql-drift.sh            # check every document
#   ./scripts/check-graphql-drift.sh --list     # print what would be checked
#
# Environment: GRAPHQL_DRIFT_GH overrides `gh` and GRAPHQL_DRIFT_ROOT the tree
# searched (the test uses both).
#
# Exit 0: every document validates. 1: at least one does not — drift, or a
# document this checker could not build variables for. 2: could not check —
# no `gh`, no credentials, no documents in the tree, or GitHub unreachable.
# Unable is never reported as clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_BIN="${GRAPHQL_DRIFT_GH:-gh}"
# The tree to search. Overridable so the test can point the real discovery at
# a fixture tree of its own; never set in normal use.
ROOT="${GRAPHQL_DRIFT_ROOT:-$SCRIPT_DIR}"

usage() {
  sed -n '3,/^# Exit 0/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_only=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage 0 ;;
    --list)    list_only=1 ;;
    *)         printf 'unknown argument: %s\n' "$arg" >&2; usage 2 ;;
  esac
done

# --- extraction ------------------------------------------------------------

# Every document in FILE, as "<line>\t<document>" with the document's newlines
# rendered as \n so one record stays one line. The `prompts/` snippets are
# delimited the same way as `lib/`'s because they are copy-pastable shell
# themselves.
extract_documents() {
  # FILE is root-relative, as discovery reports it and as a GitHub annotation
  # needs it; it is resolved against $ROOT here rather than against the
  # caller's working directory, which is not the tree searched.
  #
  # In awk rather than in bash, which is not a style preference: the bash form
  # this replaced walked each file with `${rest#…}` and counted the newlines
  # in the consumed prefix with `${prefix//[!$'\n']/}`, both of which rescan
  # the whole prefix on every document, and it spent 39 seconds of CPU on this
  # repository's seven. The line-oriented form is a few milliseconds.
  local file="$1"
  awk -v M="-f query='" -v Q="'" '
    {
      line = $0
      while (1) {
        if (!indoc) {
          p = index(line, M)
          if (p == 0) break
          startline = NR
          doc = ""
          line = substr(line, p + length(M))
          indoc = 1
        }
        # The closing delimiter is the next single quote, which is exact
        # rather than approximate: these are single-quoted *shell* strings,
        # and a single-quoted shell string cannot contain a single quote.
        q = index(line, Q)
        if (q == 0) { doc = doc line "\\n"; break }
        doc = doc substr(line, 1, q - 1)
        print startline "\t" doc
        indoc = 0
        line = substr(line, q + 1)
      }
    }
  ' "$ROOT/$file"
}

# --- rewriting -------------------------------------------------------------

# Sets `wrapped` to DOCUMENT with its operation's selection set wrapped in
# `... @skip(if:true) { … }`, and `vardefs` to the operation's variable
# definitions (empty when it declares none). Returns non-zero, saying why on
# stderr, when the document's shape is not one this checker recognises —
# which fails the run rather than skipping the document, since a document this
# cannot rewrite is a document nothing is checking.
#
# Brace and paren matching is by depth, and both are safe here: the only
# braces inside an operation are its own selection sets and input-object
# literals (`input:{pullRequestId:$id}`), all balanced. A GraphQL *string*
# literal containing an unbalanced brace would defeat it; none of these
# documents has a string literal at all, and one appearing would show up as
# the rewrite failing loudly here rather than as a wrong answer.
rewrite_document() {
  local doc="$1" n i c depth
  n=${#doc}
  wrapped=""; vardefs=""

  i=0
  while (( i < n )) && [[ "${doc:i:1}" == [[:space:]] ]]; do i=$(( i + 1 )); done
  # The operation keyword, if any — a bare `{ … }` shorthand query has none.
  while (( i < n )) && [[ "${doc:i:1}" == [A-Za-z_] ]]; do i=$(( i + 1 )); done
  while (( i < n )) && [[ "${doc:i:1}" == [[:space:]] ]]; do i=$(( i + 1 )); done
  # An operation name, if any.
  while (( i < n )) && [[ "${doc:i:1}" == [A-Za-z_0-9] ]]; do i=$(( i + 1 )); done
  while (( i < n )) && [[ "${doc:i:1}" == [[:space:]] ]]; do i=$(( i + 1 )); done

  if [[ "${doc:i:1}" == "(" ]]; then
    local start=$i
    depth=0
    while (( i < n )); do
      c="${doc:i:1}"
      [[ "$c" == "(" ]] && depth=$(( depth + 1 ))
      if [[ "$c" == ")" ]]; then
        depth=$(( depth - 1 ))
        (( depth == 0 )) && break
      fi
      i=$(( i + 1 ))
    done
    (( depth == 0 )) || { printf 'unbalanced variable definitions\n' >&2; return 1; }
    vardefs="${doc:start:i-start+1}"
    i=$(( i + 1 ))
  fi

  while (( i < n )) && [[ "${doc:i:1}" != "{" ]]; do i=$(( i + 1 )); done
  (( i < n )) || { printf 'no selection set found\n' >&2; return 1; }

  local open=$i
  depth=0
  while (( i < n )); do
    c="${doc:i:1}"
    [[ "$c" == "{" ]] && depth=$(( depth + 1 ))
    if [[ "$c" == "}" ]]; then
      depth=$(( depth - 1 ))
      (( depth == 0 )) && break
    fi
    i=$(( i + 1 ))
  done
  (( depth == 0 )) || { printf 'unbalanced selection set\n' >&2; return 1; }

  wrapped="${doc:0:open+1} ... @skip(if:true) {${doc:open+1:i-open-1}} ${doc:i}"
}

# --- variables -------------------------------------------------------------

# Appends `gh api graphql` arguments for VARDEFS to the `gh_args` array. The
# operation body is skipped but its variables are still coerced (verified
# live: an unsupplied `String!` is rejected on its own), so every declared
# variable needs a value — and the value only has to satisfy the *type*, since
# nothing resolves it.
#
# The supported set is deliberately small and closed: a type this table does
# not know fails the run, naming the file, rather than being guessed at. A
# guess that GitHub rejects reads as drift, which would make this check's own
# failure indistinguishable from the failure it exists to report.
build_variables() {
  local vardefs="$1" where="$2" pair name type
  local -a pairs=()
  [[ -n "$vardefs" ]] || return 0
  mapfile -t pairs < <(grep -oE '\$[A-Za-z_][A-Za-z_0-9]*[[:space:]]*:[[:space:]]*[^,)]+' <<<"$vardefs")
  for pair in "${pairs[@]}"; do
    name="${pair%%:*}"; name="${name#\$}"; name="${name//[[:space:]]/}"
    type="${pair#*:}"; type="${type%%=*}"; type="${type//[[:space:]]/}"; type="${type%!}"
    case "$type" in
      String|ID) gh_args+=( -f "$name=x" ) ;;
      Int)       gh_args+=( -F "$name=1" ) ;;
      Boolean)   gh_args+=( -F "$name=false" ) ;;
      *)
        printf '::error file=%s::$%s is declared %s, a type check-graphql-drift.sh cannot synthesise a value for — add it to build_variables (%s)\n' \
          "${where%%:*}" "$name" "$type" "$where"
        return 1 ;;
    esac
  done
}

# --- the check -------------------------------------------------------------

# WHY A TREE WALK AND NOT `git ls-files`, which is how `scripts/lint-shell.sh`
# beside it discovers its own file set. Because this check has to be able to
# run where it is tested, and it is tested inside the node image: the `test/`
# suite runs from `/app` in a container built with a `.dockerignore` that drops
# `.git`, and `scripts/run-tests.sh` tars the working tree in with
# `--exclude=.git` for the same reason. Discovery keyed on an index would find
# nothing there and report it as no drift, so the one case worth having — the
# real tree, walked the way the nightly walks it — could only ever have been
# asserted on a developer's checkout. That is the shape of the failure this
# whole item is about, and it is not worth repeating for the sake of matching
# a sibling script's mechanism. What tracking would have bought is that an
# untracked scratch file cannot fail the run; the nightly works from a clean
# checkout, where there are none.
#
# What is searched is every regular file in the tree, less `.git` and
# `node_modules`, and less three kinds of file that carry the delimiter
# without sending anything:
#
#   - `test/`, because the whole point of a stub is that it answers without
#     asking, and test/graphql-drift.test.sh's own fixtures include documents
#     deliberately broken to prove this check reports them;
#   - this file, which quotes the delimiter throughout its commentary above;
#   - Markdown outside `prompts/` — CHANGELOG.md, docs/, README.md — which is
#     prose *about* these documents rather than any of them. `prompts/` is the
#     deliberate exception and not an oversight: a prompt file is the
#     instruction an agent carries out, so its documents are sent as surely as
#     `lib/`'s, and `prompts/reviewer.md`'s merge-queue probe guards a push
#     that cannot be undone.
#
# Note what is *not* excluded: any shell script anywhere in the tree, whether
# or not whoever added it knew this check exists.
[[ -d "$ROOT" ]] || { printf '::error::%s is not a directory — nothing to check\n' "$ROOT"; exit 2; }
mapfile -t candidates < <(
  cd "$ROOT" || exit
  # `-r` matters: with no input at all, `xargs -0` would still run `grep`
  # once with no file arguments, and grep would read stdin and hang.
  find . \( -name .git -o -name node_modules \) -prune -o -type f -print0 \
    | xargs -r0 grep -l -I -F -e "-f query='" 2>/dev/null \
    | sed 's|^\./||' | sort
)
files=()
for candidate in "${candidates[@]}"; do
  case "$candidate" in
    test/*|scripts/check-graphql-drift.sh) continue ;;
  esac
  [[ "$candidate" == *.md && "$candidate" != prompts/* ]] && continue
  files+=( "$candidate" )
done
if (( ${#files[@]} == 0 )); then
  printf '::error::no file in the tree carries a GraphQL document — refusing to report no drift\n'
  exit 2
fi

status=0
checked=0
extracted=0
err_file="$(mktemp)" || exit 2
trap 'rm -f "$err_file"' EXIT

for file in "${files[@]}"; do
  while IFS=$'\t' read -r line encoded; do
    [[ -n "$encoded" ]] || continue
    doc="${encoded//\\n/$'\n'}"
    extracted=$(( extracted + 1 ))

    if ! rewrite_document "$doc" 2>/dev/null; then
      printf '::error file=%s,line=%s::check-graphql-drift.sh could not read the shape of this GraphQL document, so nothing is checking it\n' \
        "$file" "$line"
      status=1
      continue
    fi

    gh_args=( api graphql -f "query=$wrapped" )
    if ! build_variables "$vardefs" "$file:$line"; then
      status=1
      continue
    fi

    if (( list_only )); then
      printf '%s:%s\t%s\n' "$file" "$line" "$(tr -s '[:space:]' ' ' <<<"${doc:0:72}")"
      checked=$(( checked + 1 ))
      continue
    fi

    checked=$(( checked + 1 ))
    out="$("$GH_BIN" "${gh_args[@]}" 2>"$err_file")"
    rc=$?

    if (( rc == 0 )); then
      printf 'ok   - %s:%s\n' "$file" "$line"
      continue
    fi

    # `gh` exits non-zero for a GraphQL error and for a transport failure
    # alike, and the two must never be reported as the same thing. Its
    # diagnostics go to stderr and the response document to stdout, kept
    # apart here rather than merged with `2>&1`: `gh` writes the document
    # without a trailing newline, so a merged capture runs the JSON and the
    # word `gh:` together into one unparsable line. A stdout that does not
    # parse as a GraphQL error document is the transport case, and stderr is
    # then the only thing that says what happened.
    if ! errors="$(jq -c '.errors // empty' <<<"$out" 2>/dev/null)" || [[ -z "$errors" ]]; then
      printf '::error file=%s,line=%s::could not check this document — %s\n' \
        "$file" "$line" "$(tr '\n' ' ' <"$err_file")"
      (( status == 0 )) && status=2
      continue
    fi

    # GitHub tags what it could not *do* with a `type` (NOT_FOUND, FORBIDDEN,
    # RATE_LIMITED); a validation error carries `extensions.code` and no
    # `type`. Nothing executes here, so a `type` at all means the check did
    # not happen — which is reported as unable, never as clean and never as
    # drift.
    if [[ "$(jq -r 'map(select(.type != null)) | length' <<<"$errors")" != "0" ]]; then
      printf '::error file=%s,line=%s::could not check this document — %s\n' \
        "$file" "$line" "$(jq -r 'map("\(.type // "?"): \(.message)") | join("; ")' <<<"$errors")"
      (( status == 0 )) && status=2
      continue
    fi

    while IFS= read -r msg; do
      printf '::error file=%s,line=%s::%s\n' "$file" "$line" "$msg"
    done < <(jq -r '.[] | .message' <<<"$errors")
    status=1
  done < <(extract_documents "$file")
done

# A discovery that matched files but yielded no document is the same silent
# pass an empty file list would be, and is refused for the same reason. It
# counts what was *extracted*, never what was checked: a tree whose every
# document failed to rewrite has already failed the run above, and must report
# that failure rather than be overwritten by this one.
if (( extracted == 0 )); then
  printf '::error::found files carrying GraphQL documents but extracted none — refusing to report no drift\n'
  exit 2
fi

# Both numbers, always: a run that extracted eight documents and checked seven
# has left one unanswered, and a bare "7 checked" would read like coverage.
(( list_only )) || printf "%s of %s document(s) checked against GitHub's live schema\n" \
  "$checked" "$extracted"
exit "$status"
