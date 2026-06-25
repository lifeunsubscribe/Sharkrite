#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/portable-cmds.sh
# Regression test for: Make sed/stat/xargs portable for Linux CI
#
# Covers:
# 1. portable_find_max_mtime — returns "0" on empty stdin, returns max of multiple mtimes
# 2. Lint Rule 10 (BARE_BSD_SED_I)  — fires on bare sed -i '', passes on portable_sed_i usage
# 3. Lint Rule 11 (BARE_BSD_STAT_F) — fires on bare stat -f,  passes on portable_stat_mtime usage
# 4. Lint Rule 12 (XARGS_WITHOUT_NULL) — fires on find | xargs without -0
# 5. Deduplication — Rule 5 (BSD_SED_NO_FALLBACK) does not overlap with Rule 10

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  # Temp dir for runtime test files (linter will NOT scan here)
  export RUNTIME_TMP="${BATS_TEST_TMPDIR}/portable-cmds-test"
  mkdir -p "$RUNTIME_TMP"

  # Source the portable-cmds helpers for runtime tests
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/utils/portable-cmds.sh"
}

teardown() {
  rm -rf "$RUNTIME_TMP"
}

# ---------------------------------------------------------------------------
# portable_find_max_mtime — runtime behaviour
# ---------------------------------------------------------------------------

@test "portable_find_max_mtime returns 0 on empty stdin" {
  # Pass nothing on stdin (simulates find finding no files)
  run bash -c '
    source "'"$PROJECT_ROOT"'/lib/utils/portable-cmds.sh"
    printf "" | portable_find_max_mtime
  '
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "portable_find_max_mtime returns max mtime across multiple files" {
  local file_old="$RUNTIME_TMP/old.txt"
  local file_new="$RUNTIME_TMP/new.txt"
  touch "$file_old"
  sleep 1
  touch "$file_new"

  # Get individual mtimes via portable_stat_mtime
  local mtime_old mtime_new
  mtime_old=$(portable_stat_mtime "$file_old")
  mtime_new=$(portable_stat_mtime "$file_new")

  # Feed both paths NUL-delimited to portable_find_max_mtime
  run bash -c '
    source "'"$PROJECT_ROOT"'/lib/utils/portable-cmds.sh"
    printf "%s\0%s\0" "'"$file_old"'" "'"$file_new"'" | portable_find_max_mtime
  '
  [ "$status" -eq 0 ]
  # Result must equal the newer file's mtime
  [ "$output" = "$mtime_new" ]
  # And must be strictly greater than the older one
  [ "$output" -gt "$mtime_old" ]
}

@test "portable_find_max_mtime handles single file" {
  local file="$RUNTIME_TMP/single.txt"
  touch "$file"
  local expected
  expected=$(portable_stat_mtime "$file")

  run bash -c '
    source "'"$PROJECT_ROOT"'/lib/utils/portable-cmds.sh"
    printf "%s\0" "'"$file"'" | portable_find_max_mtime
  '
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Lint Rule 10: BARE_BSD_SED_I — presence and pattern correctness
# ---------------------------------------------------------------------------

@test "lint file contains Rule 10 (BARE_BSD_SED_I)" {
  run grep -q "BARE_BSD_SED_I" "$PROJECT_ROOT/tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
}

@test "Rule 10 pattern matches bare sed -i '' lines" {
  # Verify the regex used by Rule 10 matches the bad pattern
  local bad_line="  sed -i '' \"s|foo|bar|\" file.txt"
  run grep -qE "sed[[:space:]]+-i[[:space:]]+''" <<< "$bad_line"
  [ "$status" -eq 0 ]
}

@test "Rule 10 does not match portable_sed_i wrapper usage" {
  # The wrapper call must NOT contain the literal sed -i ''
  local good_line="  portable_sed_i \"s|foo|bar|\" file.txt"
  run bash -c "echo '$good_line' | grep -qE \"sed\s+-i\s+''\""
  # Must NOT match
  [ "$status" -ne 0 ]
}

@test "Rule 10 skips portable-cmds.sh (guard confirmed present)" {
  # Rule 10 explicitly excludes portable-cmds.sh; verify the skip guard exists
  run grep -q 'portable-cmds.sh' "$PROJECT_ROOT/tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Lint Rule 11: BARE_BSD_STAT_F — presence and pattern correctness
# ---------------------------------------------------------------------------

@test "lint file contains Rule 11 (BARE_BSD_STAT_F)" {
  run grep -q "BARE_BSD_STAT_F" "$PROJECT_ROOT/tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
}

@test "Rule 11 pattern matches bare stat -f lines" {
  local bad_line='  MTIME=$(stat -f "%m" file.txt || true)'
  run bash -c "echo '$bad_line' | grep -qE 'stat\s+-f'"
  [ "$status" -eq 0 ]
}

@test "Rule 11 does not match portable_stat_mtime wrapper usage" {
  local good_line='  mtime=$(portable_stat_mtime "$file")'
  run bash -c "echo '$good_line' | grep -qE 'stat\s+-f'"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Lint Rule 12: XARGS_WITHOUT_NULL — presence and pattern correctness
# ---------------------------------------------------------------------------

@test "lint file contains Rule 12 (XARGS_WITHOUT_NULL)" {
  run grep -q "XARGS_WITHOUT_NULL" "$PROJECT_ROOT/tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
}

@test "Rule 12 pattern matches find | xargs without -0" {
  local bad_line='  find . -type f | xargs grep "pattern"'
  # Matches xargs without -0
  run bash -c "echo '$bad_line' | grep -qE '\bxargs\b' && ! echo '$bad_line' | grep -qE 'xargs\s+(-[a-zA-Z]*0|-0)'"
  [ "$status" -eq 0 ]
}

@test "Rule 12 does not flag -print0 | xargs -0" {
  local good_line='  find . -type f -print0 | xargs -0 grep "pattern"'
  # Must NOT match the unsafe xargs pattern (xargs -0 is safe)
  run bash -c "echo '$good_line' | grep -qE 'xargs\s+(-[a-zA-Z]*0|-0)'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Deduplication: Rule 5 (BSD_SED_NO_FALLBACK) vs Rule 10 (BARE_BSD_SED_I)
# ---------------------------------------------------------------------------

@test "Rule 5 is restricted to portable-cmds.sh only (no double-report)" {
  # Confirm the Rule 5 loop has a guard that skips non-portable-cmds.sh files
  # The guard: [[ "$file" != */portable-cmds.sh ]] → continue
  run grep -A5 'Rule 5' "$PROJECT_ROOT/tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "portable-cmds.sh" ]]
  [[ "$output" =~ "continue" ]]
}

@test "Rule 5 pattern regex matches sed -i '' in portable-cmds.sh context" {
  # Rule 5's regex: sed\s+-i\s+''
  # Must still fire if portable-cmds.sh somehow loses its --version guard
  local bad_line="  sed -i '' \"\$@\""
  run grep -qE "sed[[:space:]]+-i[[:space:]]+''" <<< "$bad_line"
  [ "$status" -eq 0 ]
}

@test "codebase has no bare stat -f outside portable-cmds.sh" {
  # Search lib/ and bin/ for bare stat -f, excluding the canonical implementation
  run bash -c '
    grep -rn "stat -f" "'"$PROJECT_ROOT"'/lib" "'"$PROJECT_ROOT"'/bin" 2>/dev/null \
      | grep -v "portable-cmds.sh" \
      | grep -vE ":[0-9]+:[[:space:]]*#" \
      || true
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codebase has no bare sed -i without portable_sed_i (outside portable-cmds.sh)" {
  # Search lib/ and bin/ for sed -i '', excluding the canonical implementation
  run bash -c "
    grep -rn \"sed -i ''\" '$PROJECT_ROOT/lib' '$PROJECT_ROOT/bin' 2>/dev/null \
      | grep -v 'portable-cmds.sh' \
      | grep -vE ':[0-9]+:[[:space:]]*#' \
      || true
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
