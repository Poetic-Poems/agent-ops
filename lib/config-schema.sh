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
# Also holds cross-key rules the schema itself cannot state — each holds
# *between* two keys (or two array entries) rather than about one, which is
# outside what `additionalProperties`/`required`/etc. on a single object can
# express. `config_enabler_assignee_ok`, `config_missing_plan_path_repos`,
# `config_model_tier_floor_violations` and
# `config_required_refinement_sources_without_refiner` are `agent-cycle.sh`'s
# own startup guards; `config_duplicate_project_review_slugs` is
# `review-cycle.sh`'s. `scripts/doctor.sh` calls all five so no pipeline's
# refusal can ever drift from what `doctor.sh` reports.
#
# `config_model_tier_floor_violations` reads `lib/model-id.sh`'s
# `MODEL_TIER_RANK` table, through `model_tier_below`; both scripts that
# source this file also source that one, in whichever order, before either is
# ever called.
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

    # schema_faults($s; $p) sweeps the schema on its own terms, independent of
    # anything a config sets: `errs` below only resolves a `$ref` it walks
    # *into*, and it walks into a key only because the config has that key, so
    # a `$ref` sitting on a property the operator has omitted — or inside an
    # `items` schema behind an array the config leaves empty — was never
    # reached and its fault never reported (TD-PPagop-26081606). This walks
    # schema space instead, descending only through the keywords the
    # validator itself understands (`properties`, `items`, `$defs`) rather
    # than every `paths`, which cannot tell a schema node from a `default`,
    # `const` or `enum` value that happens to carry a `$ref` key of its own —
    # a false positive there would fail both pipelines'\'' startup gate for
    # every installation. Never chases a `$ref` to its resolved target: a
    # `$defs` entry is already visited once, on its own, as `$defs`'\''s own
    # child, so nothing here would walk it a second time through every site
    # that references it. That also means a `$defs` entry nothing currently
    # references is still swept — deliberately: catching a fault there is the
    # point of a schema-wide sweep, even though the config could never reach
    # it either way.
    def schema_fault($s; $p):
        (try deref($s) catch {"__schema_fault__": .}) as $r
        | if ($r | type) == "object" and ($r | has("__schema_fault__"))
          then ["schema.\($p): \($r.__schema_fault__)"]
          else [] end;
    def schema_faults($s; $p):
        if ($s | type) != "object" then []
        else
          schema_fault($s; $p)
          + (if ($s | has("properties")) then
               [ ($s.properties | keys_unsorted[]) as $k
                 | schema_faults($s.properties[$k];
                     (if $p == "" then "properties.\($k)" else "\($p).properties.\($k)" end))[] ]
             else [] end)
          + (if ($s | has("items")) then
               schema_faults($s.items; (if $p == "" then "items" else "\($p).items" end))
             else [] end)
          + (if ($s | has("$defs")) then
               [ ($s["$defs"] | keys_unsorted[]) as $k
                 | schema_faults($s["$defs"][$k];
                     (if $p == "" then "$defs.\($k)" else "\($p).$defs.\($k)" end))[] ]
             else [] end)
        end;

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

    (schema_faults($root; "") + errs($root; .; "config"))[]
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

# config_model_tier_floor_violations REFINER_MODEL ENABLER_MODEL IMPLEMENTER_MODEL_DEFAULT IMPLEMENTER_MODEL_TRIVIAL
# Prints one "author_key<TAB>floor_key<TAB>author_id<TAB>floor_id" line per
# pair where refiner_model or enabler_model — the two stages that can author a
# work order's context/acceptance directly rather than relay text a human or
# the Script already wrote (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirements
# 39 and 36b) — ranks below an implementer tier it might write for
# (requirement 1c, "the floor"; agent-ops#822). Empty when every rankable pair
# clears it. Takes already-resolved bare model ids, as every caller has
# already resolved them for its own purposes (requirement 1a); an empty value
# on either side of a pair is skipped (an empty model means that stage is
# disabled — a different check's business), and so is a pair `model_tier_below`
# cannot rank on one side or the other — an unranked model is `scripts/doctor.sh`'s
# own warning, not a floor violation, because this predicate cannot tell
# "definitely clears it" from "cannot tell" and must never report the latter
# as the former.
config_model_tier_floor_violations() {
  local refiner="$1" enabler="$2" impl_default="$3" impl_trivial="$4"
  local author author_key floor floor_key
  for author_key in refiner_model enabler_model; do
    case "$author_key" in
      refiner_model) author="$refiner" ;;
      enabler_model) author="$enabler" ;;
    esac
    [[ -n "$author" ]] || continue
    for floor_key in implementer_model_default implementer_model_trivial; do
      case "$floor_key" in
        implementer_model_default) floor="$impl_default" ;;
        implementer_model_trivial) floor="$impl_trivial" ;;
      esac
      [[ -n "$floor" ]] || continue
      if model_tier_below "$author" "$floor"; then
        printf '%s\t%s\t%s\t%s\n' "$author_key" "$floor_key" "$author" "$floor"
      fi
    done
  done
}

# config_required_refinement_sources_without_refiner REFINEMENT_POLICY_JSON REFINER_MODEL
# Prints the comma-joined source names whose effective `refinement_policy`
# (config) is `"required"` while REFINER_MODEL is empty — a configuration
# nobody can act on, since `prompts/coordinator.md`'s "Per-source refinement
# policy" never selects an unrefined item from a `"required"` source, and with
# no Refiner ever engaging (requirement 39's own gate on `refiner_model` being
# set) nothing ever refines one either: the source's items wait forever
# (requirement 1c; agent-ops#822, resolving `refiner_model`'s optionality).
# Empty when REFINER_MODEL is set, or no source resolves to `"required"`.
config_required_refinement_sources_without_refiner() {
  local policy_json="${1:-{\}}" refiner_model="$2"
  [[ -z "$refiner_model" ]] || { printf ''; return; }
  jq -r '(. // {}) | to_entries | map(select(.value == "required") | .key) | join(", ")' \
    <<<"$policy_json" 2>/dev/null || true
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

# config_documented_value_mismatches DEFAULTED_CONFIG_JSON SCHEMA_FILE
# Prints one `key<TAB>documented<TAB>resolved` line per leaf key whose
# `x-docs.value` documents a specific installation's choice — differs,
# semantically, from that key's own schema `default` — but the live config
# resolves to something else (issue #567: `refiner_model` documented as
# `claude-haiku-4-5-20251001` while `config.json` had never set it, so it
# silently ran the empty-string default — off — for eight days). Empty when
# every such key's resolved value matches what is documented.
#
# A key's `x-docs.value` equal to its own `default` documents the product's
# shipped behaviour, not this installation's, so it is never checked (an
# operator running below the ladder's `merge_autonomy` default, say, is not a
# documentation bug); a key with no `x-docs.value` at all, one whose
# `x-docs.value` is an object keyed `readme`/`spec` (the two documents assert
# different things there, so there is no one value to check the config
# against), and one with no schema `default` to differ from in the first
# place, are likewise skipped — each is a case this single-value comparison
# cannot be reduced to. "Differs" and "matches" are both judged on the parsed
# value a documented cell encodes, not its Markdown spelling: a documented
# `` `["a", "b"]` `` and a `default` of `["a","b"]` compare equal despite the
# whitespace, the same way `` `claude-sonnet-5` `` compares to the bare string
# it names and `*(unset)*` compares to an empty string — the same convention
# `scripts/render-config-table.sh`'s own header documents. The *reported*
# resolved value, when a mismatch is found, is rendered the way that script's
# `value_for` renders an unset `default` — a non-empty string bare in
# backticks, `*(unset)*` for an empty one, anything else as compact JSON in
# backticks — so a `scripts/doctor.sh` warning names the same cell a
# regenerated config table would show.
config_documented_value_mismatches() {
  local defaulted_config="$1" schema_file="$2"
  jq -rn --argjson cfg "$defaulted_config" --slurpfile schema "$schema_file" '
    ($schema[0]) as $root

    # Shared with config_schema_errors/config_defaults: a `$ref` is replaced
    # by its target, sibling keywords kept and winning, resolved to a
    # fixpoint and bounded against a cyclic chain.
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

    # value_for'\''s own fallback rendering (scripts/render-config-table.sh),
    # applied here to a *resolved* config value rather than a schema
    # `default`: a non-empty string bare in backticks, an empty string as
    # `*(unset)*` (the convention every `x-docs.value` already uses for one),
    # anything else as compact JSON in backticks.
    def render_value:
        if (type == "string") then
          (if . == "" then "*(unset)*" else "`" + . + "`" end)
        else "`" + (tojson) + "`" end;

    def strip_backticks:
        if (type == "string") and (length >= 2) and startswith("`") and endswith("`")
        then .[1:-1] else . end;

    # The value a documented cell (a bare `x-docs.value` string) encodes:
    # `*(unset)*` is the empty string, a backtick-wrapped JSON literal parses
    # to the value it spells, and anything else — a bare model id, a bare
    # repository slug — is the literal string between the backticks.
    def doc_semantic_value:
        strip_backticks as $inner
        | if $inner == "*(unset)*" then ""
          else ($inner | try fromjson catch null) as $parsed
            | if $parsed != null then $parsed else $inner end
          end;

    # Every leaf under `.properties`, one level of `properties` at a time —
    # `schedule` and `project_review` (and its own `defaults`) recurse the
    # same way render-config-table.sh'\''s `flatten_region` does; anything
    # without its own `properties` (after `$ref` resolution) is a leaf.
    def leaf_paths($node0; $path):
        (try deref($node0) catch null) as $node
        | if ($node == null) then empty
          elif ($node | type) == "object" and ($node | has("properties")) then
            ($node.properties | keys_unsorted[] as $k | leaf_paths($node.properties[$k]; $path + [$k]))
          else {path: $path, node: $node} end;

    [ ($root.properties // {}) | keys_unsorted[] as $k
      | leaf_paths($root.properties[$k]; [$k]) ] as $leaves

    | $leaves[]
    | select((.node["x-docs"].value?) != null)
    | select((.node["x-docs"].value | type) == "string")
    | select(.node | has("default"))
    | . as $e
    | ($e.node["x-docs"].value) as $doc_value
    | ($doc_value | doc_semantic_value) as $doc_semantic
    | select($e.node.default != $doc_semantic)
    | ($cfg | getpath($e.path)) as $resolved
    | select($resolved != null)
    | select($resolved != $doc_semantic)
    | [($e.path | join(".")), $doc_value, ($resolved | render_value)] | @tsv
  ' 2>/dev/null || true
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
