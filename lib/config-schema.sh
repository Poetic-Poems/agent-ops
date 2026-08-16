#!/usr/bin/env bash
#
# lib/config-schema.sh — validate config.json against config.schema.json.
#
# The schema is the machine-readable statement of what an installation may
# configure; this is what makes it enforceable. It exists because a
# configuration typo is the quietest failure this system has: a misspelled key
# is simply not read, and the pipeline runs on a default the operator never
# chose, for as many cycles as it takes someone to notice. `additionalProperties:
# false` throughout the schema turns that whole class loud.
#
# Deliberately a *subset* of JSON Schema, not an implementation of it: the
# keywords below are the ones config.schema.json actually uses, and the rule
# is that the schema may only use keywords this understands. A full validator
# would be a dependency (there is none available on a node beyond jq, git,
# perl and python3's standard library) or several hundred lines of jq; neither
# buys anything the product needs. Supported: type, enum, const, minimum,
# maximum, exclusiveMinimum, exclusiveMaximum, minLength, pattern, minItems,
# uniqueItems, contains, properties, required, additionalProperties (false
# only), items, and local `$ref`s into `#/$defs`.
#
# Also holds three cross-key rules the schema itself cannot state — each
# holds *between* two keys (or two array entries) rather than about one,
# which is outside what `additionalProperties`/`required`/etc. on a single
# object can express. `config_enabler_assignee_ok` and
# `config_missing_plan_path_repos` are `agent-cycle.sh`'s own startup
# guards; `config_duplicate_project_review_slugs` is `review-cycle.sh`'s.
# `scripts/doctor.sh` calls all three so no pipeline's refusal can ever drift
# from what `doctor.sh` reports.
#
# Sourced by agent-cycle.sh and scripts/doctor.sh. jq 1.6 compatible: nodes
# carry 1.7, but a host running doctor.sh before installing anything may well
# have 1.6.

# config_schema_errors CONFIG_FILE SCHEMA_FILE
# Prints one human-readable error per line, each naming the path in the config
# that is wrong. Returns 0 when the config is valid (and prints nothing), 1
# when it is not, and 2 when either file is missing or unreadable as JSON —
# a distinction doctor.sh reports differently, since a config that will not
# parse is a different conversation from one that parses and is wrong.
config_schema_errors() {
  local config_file="$1" schema_file="$2"

  if [[ ! -r "$config_file" ]]; then
    echo "config-schema: cannot read $config_file"
    return 2
  fi
  if [[ ! -r "$schema_file" ]]; then
    echo "config-schema: cannot read $schema_file"
    return 2
  fi
  if ! jq -e . "$config_file" >/dev/null 2>&1; then
    echo "config-schema: $config_file is not valid JSON"
    return 2
  fi
  if ! jq -e . "$schema_file" >/dev/null 2>&1; then
    echo "config-schema: $schema_file is not valid JSON"
    return 2
  fi

  local errors
  errors="$(jq -r --slurpfile schema "$schema_file" '
    ($schema[0]) as $root

    # A `$ref` is replaced by its target, with any sibling keywords kept and
    # winning — that is how a property reuses `#/$defs/modelId` while giving
    # its own description and default. Resolved to a fixpoint, not one hop: a
    # `$def` that itself carries a `$ref` (`requiredLabel` chaining to
    # `label`, say) must have both levels'\'' keywords survive, not just the
    # outer one. Bounded to a handful of iterations so a cyclic `$ref` cannot
    # hang jq — a chain still unresolved past the bound throws, same as a
    # target that does not exist at all (`getpath` on a missing path returns
    # `null`, and jq'\''s `null + {...}` would otherwise silently keep only
    # the sibling keywords, turning a typo'\''d `$ref` into "no constraints"
    # rather than a fault). Each caller below decides what an unresolved
    # `$ref` means for it.
    | def deref($s):
        (reduce range(0; 10) as $i
           ($s;
              if (type == "object") and has("$ref")
              then . as $cur
                | ($root | getpath($cur["$ref"] | ltrimstr("#/") | split("/"))) as $target
                | if $target == null
                  then error("$ref \($cur["$ref"]) does not resolve")
                  else $target + ($cur | del(.["$ref"]))
                  end
              else . end)) as $resolved
        | if ($resolved | type) == "object" and ($resolved | has("$ref"))
          then error("$ref chain at \($resolved["$ref"]) is too deep (or cyclic)")
          else $resolved end;

    # JSON Schema types over JSON values: `integer` is a number with nothing
    # after the point, and `number` accepts integers too.
    def type_ok($v; $want):
        ($v | type) as $t
        | if $want == "integer" then ($t == "number" and ($v | floor) == $v)
          elif $want == "number" then $t == "number"
          else $t == $want
          end;

    def errs($s0; $v; $p):
        # An unresolved `$ref` is a fault in the schema, not the config: it is
        # reported at the path it was reached from, the same way every other
        # violation is, rather than silently passed as "no constraints".
        (try deref($s0) catch {"__schema_fault__": .}) as $s
        | if ($s | type) == "object" and ($s | has("__schema_fault__"))
          then ["\($p): \($s.__schema_fault__)"]
          else
            ($v | type) as $t
            # A wrong type makes every other keyword meaningless — and
            # `minLength` against a number or `minimum` against a string
            # would compare across jq'\''s type order and invent a second,
            # misleading error. So a type mismatch is reported alone.
            | if ($s | has("type")) and (type_ok($v; $s.type) | not)
              then ["\($p): expected \($s.type), got \($t)"]
              else
                (if ($s | has("enum")) and ([$s.enum[] | select(. == $v)] | length) == 0
                 then ["\($p): \($v | tojson) is not one of: \($s.enum | join(", "))"]
                 else [] end)
              + (if ($s | has("const")) and $v != $s.const
                 then ["\($p): must be \($s.const | tojson)"] else [] end)
              + (if $t == "number" then
                   (if ($s | has("minimum")) and $v < $s.minimum
                    then ["\($p): \($v) is below the minimum \($s.minimum)"] else [] end)
                 + (if ($s | has("maximum")) and $v > $s.maximum
                    then ["\($p): \($v) is above the maximum \($s.maximum)"] else [] end)
                 + (if ($s | has("exclusiveMinimum")) and $v <= $s.exclusiveMinimum
                    then ["\($p): \($v) must be greater than \($s.exclusiveMinimum)"] else [] end)
                 + (if ($s | has("exclusiveMaximum")) and $v >= $s.exclusiveMaximum
                    then ["\($p): \($v) must be less than \($s.exclusiveMaximum)"] else [] end)
                 else [] end)
              + (if $t == "string" then
                   (if ($s | has("minLength")) and ($v | length) < $s.minLength
                    then ["\($p): must not be empty"] else [] end)
                 + (if ($s | has("pattern")) and (($v | test($s.pattern)) | not)
                    then ["\($p): \($v | tojson) does not match \($s.pattern)"] else [] end)
                 else [] end)
              + (if $t == "object" then
                   # `has(.)` would resolve its argument against `has`'\''s
                   # own input rather than the key in hand, so every key is
                   # bound before it is used. Same reason below.
                   [ ($s.required // [])[] as $k | select(($v | has($k)) | not)
                     | "\($p): missing required key \"\($k)\"" ]
                 + (if ($s | has("additionalProperties")) and $s.additionalProperties == false
                    then [ ($v | keys_unsorted[]) as $k
                           | select((($s.properties // {}) | has($k)) | not)
                           | "\($p): unknown key \"\($k)\"" ]
                    else [] end)
                 + [ ($v | keys_unsorted[]) as $k
                     | select(($s.properties // {}) | has($k))
                     | errs($s.properties[$k]; $v[$k]; "\($p).\($k)")[] ]
                 else [] end)
              + (if $t == "array" then
                   (if ($s | has("minItems")) and ($v | length) < $s.minItems
                    then ["\($p): needs at least \($s.minItems) item(s)"] else [] end)
                 + (if ($s | has("uniqueItems")) and $s.uniqueItems == true
                       and ($v | length) != ($v | unique | length)
                    then ["\($p): contains duplicate entries"] else [] end)
                 + (if ($s | has("items"))
                    then [ range($v | length) as $i
                           | errs($s.items; $v[$i]; "\($p)[\($i)]")[] ]
                    else [] end)
                 # `contains`: at least one entry must satisfy the subschema.
                 # When that subschema is a bare `const` — the only form the
                 # schema uses today — the message names the missing value,
                 # because "no entry satisfies `contains`" would send the
                 # operator to this file to find out what was wanted.
                 + (if ($s | has("contains"))
                    then (if ([ range($v | length) as $i
                                | select((errs($s.contains; $v[$i]; "\($p)[\($i)]") | length) == 0) ]
                              | length) == 0
                          then [ "\($p): " +
                                 (if (($s.contains | type) == "object") and ($s.contains | has("const"))
                                  then "must include \($s.contains.const | tojson)"
                                  else "no entry satisfies its `contains` subschema" end) ]
                          else [] end)
                    else [] end)
                 else [] end)
              end
          end;

    errs($root; .; "config")[]
  ' "$config_file" 2>&1)"

  if [[ -n "$errors" ]]; then
    printf '%s\n' "$errors"
    return 1
  fi
  return 0
}

# config_defaults CONFIG_FILE SCHEMA_FILE
# Prints CONFIG_FILE merged with every default config.schema.json declares, so
# a caller reads a fully-populated object and never repeats a `// literal` of
# its own. A key already set — including inside a nested object or an array
# item such as `repos[]` — is left exactly as the config wrote it; a key that
# is absent *or explicitly `null`* takes the schema's `default` (the same two
# cases jq's own `//` treats as missing, which is the operator every call site
# this replaces used to spell out by hand). An object with no default of its
# own but whose properties do — `schedule` is the case in point — is still
# synthesised whole when absent, so every leaf under it reads its default too;
# a key with no schema default anywhere on its path (a required field with
# nothing to fall back to, `project_review.defaults.model` for instance)
# passes through unchanged. This performs no validation of its own — a config invalid against
# the schema is still merged, defaults and all, since a caller that wants the
# gate calls config_schema_errors first.
config_defaults() {
  local config_file="$1" schema_file="$2"
  jq -c --slurpfile schema "$schema_file" '
    ($schema[0]) as $root

    # Shared with config_schema_errors: a `$ref` is replaced by its target,
    # with any sibling keywords kept and winning, resolved to a fixpoint and
    # bounded against a cyclic chain — see that function'\''s own comment.
    # This function performs no validation of its own (that gate is
    # config_schema_errors'\''), so an unresolved `$ref` here just means there
    # is no `default` to find at that hop: fill leaves the value as it was
    # rather than throwing.
    | def deref($s):
        (reduce range(0; 10) as $i
           ($s;
              if (type == "object") and has("$ref")
              then . as $cur
                | ($root | getpath($cur["$ref"] | ltrimstr("#/") | split("/"))) as $target
                | if $target == null
                  then error("$ref \($cur["$ref"]) does not resolve")
                  else $target + ($cur | del(.["$ref"]))
                  end
              else . end)) as $resolved
        | if ($resolved | type) == "object" and ($resolved | has("$ref"))
          then error("$ref chain at \($resolved["$ref"]) is too deep (or cyclic)")
          else $resolved end;

    def fill($s0; $v):
        (try deref($s0) catch null) as $s
        | if ($s == null) then $v
          elif ($s | has("properties")) then
            (if ($v | type) == "object" then $v else {} end) as $obj
            | reduce ($s.properties | keys_unsorted[]) as $k
                ($obj;
                   (try deref($s.properties[$k]) catch null) as $ps
                   | ($obj[$k]) as $cur
                   | if ($cur != null) then
                       .[$k] = fill($s.properties[$k]; $cur)
                     elif ($ps != null) and ($ps | has("default")) then
                       .[$k] = $ps.default
                     elif ($ps != null) and ($ps | has("properties")) then
                       (fill($s.properties[$k]; {})) as $nested
                       | if ($nested | length) > 0 then .[$k] = $nested else . end
                     else . end)
          elif ($s | has("items")) and (($v | type) == "array") then
            [ $v[] | fill($s.items; .) ]
          else
            $v
          end;

    fill($root; .)
  ' "$config_file"
}

# config_enabler_assignee_ok ENABLER_MODEL ENABLER_ASSIGNEE
# True (exit 0) unless ENABLER_MODEL is set and ENABLER_ASSIGNEE is not — the
# one combination agent-cycle.sh refuses to start with, because an escalation
# raised unassigned would be excluded from no repo's `issues` source and the
# pipeline could go on to select it as its own work. Takes the two values
# rather than a file, since every caller has already read and null-normalised
# them for its own purposes.
config_enabler_assignee_ok() {
  local enabler_model="$1" enabler_assignee="$2"
  [[ -z "$enabler_model" || -n "$enabler_assignee" ]]
}

# config_missing_plan_path_repos REPOS_JSON
# Given config.json's `repos` array (as JSON text), prints the comma-joined
# slugs that list the `implementation-plan` source without an
# `implementation_plan_path` — the one place that source's path is read from.
# Empty when every repo using the source configures one.
config_missing_plan_path_repos() {
  local repos_json="$1"
  jq -r '[.[] | select((.sources // []) | any(. == "implementation-plan"))
              | select((.implementation_plan_path // "") == "") | .slug]
         | join(", ")' <<<"$repos_json"
}

# config_duplicate_project_review_slugs PROJECT_REVIEW_REPOS_JSON
# Given an array of objects each carrying a `slug` — config.json's
# `project_review.repos` itself, or config_project_review_repos's resolved
# output, both shaped alike — prints the comma-joined slugs that name more
# than one entry. Requirement 342's resolution rule assumes exactly one entry
# per repository; two entries for the same slug leave no way to say which
# one's overrides apply, so review-cycle.sh refuses to start rather than
# silently letting the later entry win. Empty when every slug is unique
# (including the vacuous case of an empty array).
config_duplicate_project_review_slugs() {
  local repos_json="$1"
  jq -r '[.[].slug] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' <<<"$repos_json"
}

# config_project_review_repos DEFAULTED_CONFIG_JSON
# `project_review.repos`, each entry resolved against `project_review.defaults`
# per requirement 342's rule: a key present and non-null on the repo's own
# entry wins, `defaults[key]` otherwise; `slug` is never defaulted. One
# implementation shared by every reader (review-cycle.sh, scripts/doctor.sh,
# lib/labels.sh's caller) so they cannot resolve the same repository two
# different ways. Takes the already-`config_defaults`-merged config, as every
# caller already has one; prints `[]` (never fails) when `project_review` is
# absent or malformed, so a caller need not special-case the optional block.
#
# Each entry also carries `model_key`: the precise config path `model`'s
# value was resolved from — `project_review.repos[<i>].model` when this
# repository overrides it, `project_review.defaults.model` otherwise — so a
# caller passing `model` to `resolve_model_id` can name that path rather than
# the generic `project_review.model` in a resolution error.
config_project_review_repos() {
  local defaulted_config="$1"
  jq -c '
    (.project_review.defaults // {}) as $d |
    [ range(0; (.project_review.repos // []) | length) as $i |
      (.project_review.repos[$i]) as $r |
      { slug: $r.slug,
        model: ($r.model // $d.model),
        model_key: (if ($r.model != null)
                     then "project_review.repos[\($i)].model"
                     else "project_review.defaults.model" end),
        pr_label: ($r.pr_label // $d.pr_label),
        branch_prefix: ($r.branch_prefix // $d.branch_prefix),
        min_days_between_reviews: ($r.min_days_between_reviews // $d.min_days_between_reviews),
        not_before: ($r.not_before // $d.not_before // ""),
        timeout_review: ($r.timeout_review // $d.timeout_review),
        inactivity_review: ($r.inactivity_review // $d.inactivity_review) } ]
  ' <<<"$defaulted_config" 2>/dev/null || printf '[]'
}
