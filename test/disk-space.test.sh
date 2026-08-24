#!/usr/bin/env bash
#
# test/disk-space.test.sh — regression test for lib/disk-space.sh
# (agent-ops#756): the pure free-space arithmetic doctor.sh's advisory
# warning and agent-cycle.sh's pre-clone stand-down gate (requirement 2.0c)
# share, so the two cannot silently disagree about what "low" means.
#
# test/disk-space-wiring.test.sh covers whether the cycle actually acts on
# these functions' verdicts; this file covers only the functions themselves,
# against a stubbed `df` so no assertion depends on this host's real free
# space.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/disk-space.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# stub_df AVAIL_KB — a `df -Pk` stand-in printing a well-formed two-line
# response whose only figure that matters is the fourth (Available) column,
# the same one the real `df -Pk` reports it at.
stub_df() {
  cat > "$stub_dir/df" <<EOF
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
printf '/dev/sda1 1000000 1 %s 1%% /\n' "$1"
EOF
  chmod +x "$stub_dir/df"
  PATH="$stub_dir:$PATH"
}

# missing_df — a `df` that always fails, the way an unreadable meter looks.
missing_df() {
  cat > "$stub_dir/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$stub_dir/df"
  PATH="$stub_dir:$PATH"
}

# --- disk_space_free_kb -----------------------------------------------------

stub_df 5000000
assert_eq "disk_space_free_kb reads the Available column" \
  "5000000" "$(disk_space_free_kb /some/path)"

missing_df
assert_eq "disk_space_free_kb is empty when df fails, never 0" \
  "" "$(disk_space_free_kb /some/path)"

assert_eq "disk_space_free_kb is empty for an empty path" \
  "" "$(disk_space_free_kb '')"

# --- disk_space_verdict ------------------------------------------------------
# min_bytes is converted to KiB (min_bytes / 1024) for the comparison.

assert_eq "verdict is low when free KiB is below the floor" \
  "low" "$(disk_space_verdict 1000 2097152000)"   # 1000 KiB free, floor ~2 GiB
assert_eq "verdict is ok when free KiB meets the floor exactly" \
  "ok" "$(disk_space_verdict 2048000 2097152000)" # 2048000 KiB == floor/1024
assert_eq "verdict is ok when free KiB is above the floor" \
  "ok" "$(disk_space_verdict 3000000 2097152000)"
assert_eq "verdict is ok when the floor is 0 (check off), however low free space is" \
  "ok" "$(disk_space_verdict 0 0)"
assert_eq "verdict is ok when free KiB is unreadable (empty) — no evidence of a full disk" \
  "ok" "$(disk_space_verdict '' 2097152000)"
assert_eq "verdict is ok when free KiB is non-numeric" \
  "ok" "$(disk_space_verdict 'unknown' 2097152000)"
assert_eq "verdict is low at exactly zero free KiB with a floor set" \
  "low" "$(disk_space_verdict 0 2097152000)"

# --- disk_space_describe -----------------------------------------------------

desc="$(disk_space_describe /data/workspace 1024000 2147483648)"
assert_eq "describe names the path" \
  "yes" "$(if [[ "$desc" == "/data/workspace "* ]]; then echo yes; else echo no; fi)"
assert_eq "describe states the free MiB (1024000 KiB = 1000 MiB)" \
  "yes" "$(if [[ "$desc" == *"1000 MiB free"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe states the floor in MiB (2147483648 bytes = 2048 MiB)" \
  "yes" "$(if [[ "$desc" == *"2048 MiB this cycle needs"* ]]; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All disk-space assertions passed."
  exit 0
else
  echo "$failures disk-space assertion(s) FAILED."
  exit 1
fi
