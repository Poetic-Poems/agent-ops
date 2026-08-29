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
# THE REQUEST IS A JSON BODY, not `-f query=…` arguments. `gh api graphql`
# builds one map from every `-f`/`-F` pair and lifts all but `query` into
# `variables`, so a document declaring a variable actually named `$query` (or
# `$operationName`) collides with the reserved key that carries the document
# itself: gh 2.96.0 refuses the call outright with `unexpected override
# existing field under "query"`, and other versions resolve it last-wins and
# send the placeholder *as* the document. Either way a perfectly valid
# document reads as this check's own failure, which is precisely what the
# variable table below refuses to risk. GitHub's own canonical search form
# (`query($query:String!, …){ search(query:$query, …) }`) is the obvious way
# to trip it. Building `{query, variables}` and posting it with
# `--input` has no reserved key, and carries variable *types* through JSON
# rather than through `-f`-versus-`-F`. The body goes to a temp file rather
# than to `--input -`, because the wrapper below retries a rate-limited call
# and a retry cannot re-read a consumed stdin.
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
# DISCOVERY IS A SEARCH, NEVER A LIST, and it is checked from the other side.
# The documents are found by walking the tree for `-f query='`, the one form
# all of them use, rather than from a list somebody maintains — for the reason
# `.github/workflows/td-tooling-drift.yml` gives about its own manifest: a
# hard-coded list can only cover what someone already thought to add to it, so
# the document added tomorrow is invisible to the very check meant to cover
# it. But a search keyed on one spelling is a list of whoever happened to
# write that spelling, and `-f query="…"`, `--field query=…` or a document
# assembled in a variable would all be just as idiomatic and just as
# invisible. So every file that mentions `api graphql` at all must yield at
# least one document, and a file that mentions it and yields none fails the
# run. Finding *no* document anywhere fails too, and a file that opens a
# document it never closes fails rather than contributing nothing. None of
# these is ever a quiet pass. `prompts/` counts as a source of documents:
# those are sent by the agents this repository operates, and
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
# Exit 0: every document validates.
# Exit 1: at least one document is wrong — a field, argument or variable type
#   GitHub no longer recognises, a document whose shape this cannot read, or a
#   variable type it cannot synthesise a value for.
# Exit 2: at least one document was not checked at all — none found, a file
#   that mentions `api graphql` and yields no document, an unterminated
#   document, no `gh`, no credentials, or GitHub unreachable or refusing.
# Where both apply, **2 wins**: a run that could not answer for every document
# has not established the "no drift" half of its verdict either, and saying 1
# would claim a survey it did not complete. Any drift found is still printed
# and annotated. Unable is never reported as clean, and never as drift.
# `--list`'s own exit status reports only whether it could list (0 listed
# something, 2 nothing to list); it validates nothing, so it never returns 1.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than turning the
# nightly red. See lib/github-limit.sh. That matters more here than for a work
# source that merely degrades: by this check's own design a red run is meant
# to become work, so a transient secondary limit would otherwise spend a
# Co-Ordinator and an Implementer on nothing. `"$GH_BIN"` with the default
# `GH_BIN=gh` resolves to the function this defines; a test pointing
# GRAPHQL_DRIFT_GH at a path deliberately bypasses it.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

GH_BIN="${GRAPHQL_DRIFT_GH:-gh}"
# The tree to search. Overridable so the test can point the real discovery at
# a fixture tree of its own; never set in normal use.
ROOT="${GRAPHQL_DRIFT_ROOT:-$SCRIPT_DIR}"

# Prints the header block whole, rather than to the first line matching some
# pattern inside it: the `sed -n '3,/^# Exit 0/p'` idiom this used to copy
# from scripts/run-tests.sh stops *on* that line, so the entire exit-code
# contract below it — the part a caller reading `--help` most needs — was
# never printed at all.
usage() {
  awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
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

# Every document in FILE, one record per line, as either
#
#   DOC<TAB><line><TAB><document with newlines rendered as \n>
#   UNTERMINATED<TAB><line>
#
# The opening delimiter is `-f query='` **at an argv token boundary** — start
# of line, or preceded by whitespace — and the closing one is the next `'`.
# The closing rule is exact rather than approximate: these are single-quoted
# *shell* strings, and a single-quoted shell string cannot contain a single
# quote. The boundary rule is what keeps prose out: a prompt file explaining
# the form writes it inside a Markdown code span, where the character before
# `-f` is a backtick, and without the rule that prose opens a document whose
# closing quote is the *real* call's own — emitting the prose as one garbage
# document and swallowing the query that mattered.
#
# A document still open at end of file is reported rather than dropped. That
# is the silent pass this whole item is about: a typographic quote instead of
# an apostrophe used to make `awk` run to EOF and print nothing, so the file
# contributed no documents while the global "found nothing" guard stayed
# quiet because other files had.
#
# In awk rather than in bash, which is not a style preference: the bash form
# this replaced walked each file with `${rest#…}` and counted the newlines in
# the consumed prefix with `${prefix//[!$'\n']/}`, both of which rescan the
# whole prefix on every document, and it spent 39 seconds of CPU on this
# repository's seven. The line-oriented form is a few milliseconds.
extract_documents() {
  # FILE is root-relative, as discovery reports it and as a GitHub annotation
  # needs it; it is resolved against $ROOT here rather than against the
  # caller's working directory, which is not the tree searched.
  local file="$1"
  awk -v M="-f query='" -v Q="'" '
    {
      line = $0
      pos = 0                      # characters of $0 already consumed
      while (1) {
        if (!indoc) {
          p = index(line, M)
          if (p == 0) break
          # An argv token boundary, or it is prose about the form rather than
          # a use of it.
          if (pos + p > 1 && substr($0, pos + p - 1, 1) !~ /[ \t]/) {
            pos += p + length(M) - 1
            line = substr(line, p + length(M))
            continue
          }
          startline = NR
          doc = ""
          pos += p + length(M) - 1
          line = substr(line, p + length(M))
          indoc = 1
        }
        q = index(line, Q)
        if (q == 0) { doc = doc line "\\n"; break }
        doc = doc substr(line, 1, q - 1)
        print "DOC\t" startline "\t" doc
        indoc = 0
        pos += q
        line = substr(line, q + 1)
      }
    }
    END { if (indoc) print "UNTERMINATED\t" startline }
  ' "$ROOT/$file"
}

# --- rewriting -------------------------------------------------------------

# Sets `wrapped` to DOCUMENT with its operation's selection set wrapped in
# `... @skip(if:true) { … }`, and `vardefs` to the operation's variable
# definitions (empty when it declares none). Returns non-zero, saying why on
# stderr, when the document's shape is not one this checker recognises —
# which fails the run rather than skipping the document, since a document this
# cannot rewrite is a document nothing is checking. The three reasons are
# distinct and are passed through to the annotation by the caller: they point
# at different ends of the document and have different fixes.
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
    (( depth == 0 )) || { printf 'its variable definitions never close\n' >&2; return 1; }
    vardefs="${doc:start:i-start+1}"
    i=$(( i + 1 ))
  fi

  while (( i < n )) && [[ "${doc:i:1}" != "{" ]]; do i=$(( i + 1 )); done
  (( i < n )) || { printf 'it has no selection set\n' >&2; return 1; }

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
  (( depth == 0 )) || { printf 'its selection set never closes\n' >&2; return 1; }

  wrapped="${doc:0:open+1} ... @skip(if:true) {${doc:open+1:i-open-1}} ${doc:i}"
}

# --- variables -------------------------------------------------------------

# Sets `variables` to a JSON object giving every variable VARDEFS declares a
# value of the right type. The operation body is skipped but its variables are
# still coerced (verified live: an unsupplied `String!` is rejected on its
# own), so every declared variable needs one — and the value only has to
# satisfy the *type*, since nothing resolves it.
#
# The supported set is deliberately small and closed: a type this table does
# not know fails the run, naming the file, the line and the variable, rather
# than being guessed at. A guess that GitHub rejects reads as drift, which
# would make this check's own failure indistinguishable from the failure it
# exists to report. A list type takes `[]`, which satisfies any `[T]` — GraphQL
# does not have a non-empty list — and was confirmed live.
build_variables() {
  local vardefs="$1" file="$2" line="$3" pair name type value
  local -a pairs=()
  variables="{}"
  [[ -n "$vardefs" ]] || return 0
  mapfile -t pairs < <(grep -oE '\$[A-Za-z_][A-Za-z_0-9]*[[:space:]]*:[[:space:]]*[^,)]+' <<<"$vardefs")
  for pair in "${pairs[@]}"; do
    name="${pair%%:*}"; name="${name#\$}"; name="${name//[[:space:]]/}"
    type="${pair#*:}"; type="${type%%=*}"; type="${type//[[:space:]]/}"; type="${type%!}"
    case "$type" in
      \[*)       value='[]' ;;
      String|ID) value='"x"' ;;
      Int)       value='1' ;;
      Float)     value='1.5' ;;
      Boolean)   value='false' ;;
      *)
        printf '::error file=%s,line=%s::$%s is declared %s, a type check-graphql-drift.sh cannot synthesise a value for — add it to build_variables, and until then nothing is checking this document\n' \
          "$file" "$line" "$name" "$type"
        return 1 ;;
    esac
    variables="$(jq -c --arg n "$name" --argjson v "$value" '.[$n] = $v' <<<"$variables")" || return 1
  done
}

# --- discovery -------------------------------------------------------------

# Every regular file in the tree, less `.git` and `node_modules`, and less
# three kinds of file that carry the delimiter without sending anything:
#
#   - `test/`, because the whole point of a stub is that it answers without
#     asking, and test/graphql-drift.test.sh's own fixtures include documents
#     deliberately broken to prove this check reports them;
#   - this file, which quotes the delimiter throughout its commentary above;
#   - Markdown outside `prompts/` — CHANGELOG.md, docs/, README.md — which is
#     prose *about* these documents rather than any of them. `prompts/` is the
#     deliberate exception and not an oversight: a prompt file is the
#     instruction an agent carries out, so its documents are sent as surely as
#     `lib/`'s.
#
# Note what is *not* excluded: any shell script anywhere in the tree, whether
# or not whoever added it knew this check exists.
#
# A tree walk rather than `git ls-files`, which is how `scripts/lint-shell.sh`
# beside it discovers its own file set. Because this check has to be able to
# run where it is tested, and it is tested inside the node image: the `test/`
# suite runs from `/app` in a container built with a `.dockerignore` that
# drops `.git`, and `scripts/run-tests.sh` tars the working tree in with
# `--exclude=.git` for the same reason. Discovery keyed on an index would find
# nothing there and report it as no drift, so the one case worth having — the
# real tree, walked the way the nightly walks it — could only ever have been
# asserted on a developer's checkout. That is the shape of the failure this
# whole item is about. What tracking would have bought is that an untracked
# scratch file cannot fail the run; the nightly works from a clean checkout,
# where there are none.
search_tree() {  # <grep-pattern> — prints matching root-relative paths
  local pattern="$1" candidate
  local -a found=()
  mapfile -t found < <(
    cd "$ROOT" || exit
    # `-r` matters: with no input at all, `xargs -0` would still run `grep`
    # once with no file arguments, and grep would read stdin and hang.
    find . \( -name .git -o -name node_modules \) -prune -o -type f -print0 \
      | xargs -r0 grep -l -I -F -e "$pattern" 2>/dev/null \
      | sed 's|^\./||' | sort
  )
  for candidate in "${found[@]}"; do
    case "$candidate" in
      test/*|scripts/check-graphql-drift.sh) continue ;;
    esac
    [[ "$candidate" == *.md && "$candidate" != prompts/* ]] && continue
    printf '%s\n' "$candidate"
  done
}

# --- the check -------------------------------------------------------------

[[ -d "$ROOT" ]] || { printf '::error::%s is not a directory — nothing to check\n' "$ROOT"; exit 2; }

mapfile -t files < <(search_tree "-f query='")
mapfile -t callers < <(search_tree "api graphql")

if (( ${#files[@]} == 0 )); then
  printf '::error::no file in the tree carries a GraphQL document — refusing to report no drift\n'
  exit 2
fi

# Two independent verdicts, never collapsed into one counter. `saw_drift` is
# "GitHub answered, and the answer was that this document is wrong";
# `saw_unable` is "no answer was obtained". The old single `status` let an
# early 1 swallow every later 2, so a run that validated one document, found
# it drifted, and then failed to check the other six exited 1 — claiming a
# survey it never completed.
saw_drift=0
saw_unable=0
# `checked` counts documents GitHub actually returned a verdict for, so the
# summary can say how much of what was found was answered. It is incremented
# *after* the call and only on a complete answer: counting attempts made
# `7 of 7 document(s) checked` the tail of a run in which every single call
# had failed on `Bad credentials`.
checked=0
extracted=0
declare -A per_file=()

body_file="$(mktemp)" || exit 2
err_file="$(mktemp)" || { rm -f "$body_file"; exit 2; }
trap 'rm -f "$body_file" "$err_file"' EXIT

# Flattens a GraphQL message onto one line. A `::error` workflow command ends
# at the first newline, and GitHub returns multi-line messages for some
# validation failures (a parse error quotes the offending source with a caret
# beneath it), so an unflattened message shows in the Actions UI as a
# truncated fragment with the remainder loose in the log.
flatten='gsub("[\r\n]+"; " ") | gsub(" +"; " ")'

for file in "${files[@]}"; do
  per_file["$file"]=0
  while IFS=$'\t' read -r kind line encoded; do
    if [[ "$kind" == "UNTERMINATED" ]]; then
      if (( list_only )); then
        printf '%s:%s\t!! a document opens here and is never closed\n' "$file" "$line"
        continue
      fi
      printf '::error file=%s,line=%s::a GraphQL document opens here and is never closed — check for a typographic quote in place of an apostrophe; nothing is checking it, and the rest of this file was not scanned\n' \
        "$file" "$line"
      saw_unable=1
      continue
    fi
    [[ -n "$encoded" ]] || continue
    doc="${encoded//\\n/$'\n'}"
    extracted=$(( extracted + 1 ))
    per_file["$file"]=$(( per_file["$file"] + 1 ))

    if (( list_only )); then
      # A listing, never a verdict: what would be checked is listed whether or
      # not it can be rewritten, so `--list` over a tree whose only document is
      # malformed prints that document rather than nothing at all.
      printf '%s:%s\t%s\n' "$file" "$line" "$(tr -s '[:space:]' ' ' <<<"${doc:0:72}")"
      continue
    fi

    # Its stderr goes to a file, never to `$(rewrite_document …)`: a command
    # substitution runs the function in a subshell, and the `wrapped` and
    # `vardefs` it sets there would not survive back into this loop.
    if ! rewrite_document "$doc" 2>"$err_file"; then
      printf '::error file=%s,line=%s::check-graphql-drift.sh could not read the shape of this GraphQL document — %s — so nothing is checking it\n' \
        "$file" "$line" "$(tr -d '\n' <"$err_file")"
      saw_drift=1
      continue
    fi

    if ! build_variables "$vardefs" "$file" "$line"; then
      saw_drift=1
      continue
    fi

    jq -nc --arg q "$wrapped" --argjson v "$variables" '{query: $q, variables: $v}' \
      > "$body_file" 2>/dev/null || { saw_unable=1; continue; }

    # stdout and stderr are kept apart rather than merged with `2>&1`: `gh`
    # writes the response document without a trailing newline, so a merged
    # capture runs the JSON and the word `gh:` together into one unparsable
    # line. A stdout that does not parse as a GraphQL error document is the
    # transport case, and stderr is then the only thing that says what
    # happened.
    out="$("$GH_BIN" api graphql --input "$body_file" 2>"$err_file")"
    rc=$?

    if (( rc == 0 )); then
      printf 'ok   - %s:%s\n' "$file" "$line"
      checked=$(( checked + 1 ))
      continue
    fi

    if ! errors="$(jq -c '.errors // empty' <<<"$out" 2>/dev/null)" || [[ -z "$errors" ]]; then
      printf '::error file=%s,line=%s::could not check this document — %s\n' \
        "$file" "$line" "$(tr '\n' ' ' <"$err_file")"
      saw_unable=1
      continue
    fi

    # GitHub tags what it could not *do* with a `type` (NOT_FOUND, FORBIDDEN,
    # RATE_LIMITED); a validation error carries `extensions.code` and no
    # `type`. Nothing executes here, so a `type` means the check did not
    # happen. The array is *partitioned* rather than tested as a whole: one
    # response can carry both — a token without reach for one field while
    # another has genuinely moved — and short-circuiting on the typed one used
    # to discard the drift beside it without ever printing it.
    typed="$(jq -c "[.[] | select(.type != null)] | map(\"\\(.type): \\(.message | $flatten)\")" <<<"$errors")"
    untyped="$(jq -c "[.[] | select(.type == null)] | map(.message | $flatten)" <<<"$errors")"

    if [[ "$(jq -r 'length' <<<"$untyped")" != "0" ]]; then
      while IFS= read -r msg; do
        printf '::error file=%s,line=%s::%s\n' "$file" "$line" "$msg"
      done < <(jq -r '.[]' <<<"$untyped")
      saw_drift=1
    fi
    if [[ "$(jq -r 'length' <<<"$typed")" != "0" ]]; then
      printf '::error file=%s,line=%s::could not check this document — %s\n' \
        "$file" "$line" "$(jq -r 'join("; ")' <<<"$typed")"
      saw_unable=1
    else
      # A complete answer, even though the answer was drift.
      checked=$(( checked + 1 ))
    fi
  done < <(extract_documents "$file")
done

# The other side of "discovery is a search, never a list": a call site written
# `-f query="…"`, `--field query=…`, or assembled in a variable is invisible to
# the walk above, and no counter can notice it while the other documents still
# exist. A file that talks to the GraphQL API and yields no document is that
# gap made visible.
for file in "${callers[@]}"; do
  [[ -n "${per_file[$file]+set}" && "${per_file[$file]:-0}" != "0" ]] && continue
  if (( list_only )); then
    printf '%s:-\t!! calls api graphql, no document recognised\n' "$file"
    continue
  fi
  printf '::error file=%s::this file calls api graphql but no GraphQL document could be read from it — discovery recognises only the -f query=<single-quoted> form at an argv token boundary, so this call site is unchecked; write it that way or extend the scanner\n' \
    "$file"
  saw_unable=1
done

if (( list_only )); then
  # --list validates nothing, so its status reports only whether it could
  # list — the same contract scripts/run-tests.sh's own --list follows.
  (( extracted > 0 )) || { printf '::error::no GraphQL document could be listed\n'; exit 2; }
  exit 0
fi

# A discovery that matched files but yielded no document is the same silent
# pass an empty file list would be, and is refused for the same reason. It
# counts what was *extracted*, never what was checked: a tree whose every
# document failed to rewrite has already failed the run above, and must report
# that failure rather than be overwritten by this one.
if (( extracted == 0 )); then
  printf '::error::found files carrying GraphQL documents but extracted none — refusing to report no drift\n'
  exit 2
fi

# Both numbers, always: a run that extracted eight documents and answered
# seven has left one unanswered, and a bare "7 checked" would read like
# coverage.
printf "%s of %s document(s) checked against GitHub's live schema\n" "$checked" "$extracted"

(( saw_unable )) && exit 2
(( saw_drift )) && exit 1
exit 0
