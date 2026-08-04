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
# uniqueItems, properties, required, additionalProperties (false only), items,
# and local `$ref`s into `#/$defs`.
#
# Sourced by scripts/doctor.sh. jq 1.6 compatible: nodes carry 1.7, but a host
# running doctor.sh before installing anything may well have 1.6.

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
    # its own description and default.
    | def deref($s):
        if ($s | type) == "object" and ($s | has("$ref"))
        then ($root | getpath($s["$ref"] | ltrimstr("#/") | split("/")))
             + ($s | del(.["$ref"]))
        else $s end;

    # JSON Schema types over JSON values: `integer` is a number with nothing
    # after the point, and `number` accepts integers too.
    def type_ok($v; $want):
        ($v | type) as $t
        | if $want == "integer" then ($t == "number" and ($v | floor) == $v)
          elif $want == "number" then $t == "number"
          else $t == $want
          end;

    def errs($s0; $v; $p):
        deref($s0) as $s
        | ($v | type) as $t
        # A wrong type makes every other keyword meaningless — and `minLength`
        # against a number or `minimum` against a string would compare across
        # jq'\''s type order and invent a second, misleading error. So a type
        # mismatch is reported alone.
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
               # `has(.)` would resolve its argument against `has`'\''s own
               # input rather than the key in hand, so every key is bound
               # before it is used. Same reason below.
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
             else [] end)
          end;

    errs($root; .; "config")[]
  ' "$config_file" 2>&1)"

  if [[ -n "$errors" ]]; then
    printf '%s\n' "$errors"
    return 1
  fi
  return 0
}
