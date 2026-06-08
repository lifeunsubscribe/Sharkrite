#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/*.sh, lib/core/*.sh, tools/sharkrite-lint.sh
# Regression test for: Sweep codebase for set -e + pipefail silent-death
#
# Bug pattern: VAR=$(... | grep ...) under set -euo pipefail silently kills
# the script when grep finds no match (exit 1), because the pipeline exits 1,
# command substitution returns 1, and the script dies with no error output.
#
# Fix: Add || true to all such patterns: VAR=$(... | grep ... || true)
#
# This test verifies that:
# 1. The lint rule detects unsafe patterns
# 2. A deliberately-no-match grep either fails gracefully OR continues with empty value
# 3. The script does NOT silently die with no output

setup() {
  # Create temp dir for runtime test scripts
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  mkdir -p "$RITE_TEST_ROOT"

  # Create temp dir for lint test scripts (inside project lib/)
  # BATS_TEST_DIRNAME = tests/regression/ — go up two levels to reach project root
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export RITE_LINT_TEST_DIR="$PROJECT_ROOT/lib/test-fixtures-temp"
  mkdir -p "$RITE_LINT_TEST_DIR"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
  rm -rf "$RITE_LINT_TEST_DIR"
}

@test "lint rule detects unsafe VAR=\$(... | grep) pattern" {
  # Create a test script with unsafe pattern in a location the linter scans
  cat > "$RITE_LINT_TEST_DIR/unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This is unsafe - no || true
RESULT=$(echo "foo" | grep "bar")
echo "Result: $RESULT"
EOF

  # Run the lint rule
  cd "$BATS_TEST_DIRNAME/../.."  # Project root (tests/regression/ → project root)
  run tools/sharkrite-lint.sh

  # Should fail with violation
  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "unsafe.sh" ]]
}

@test "lint rule allows safe VAR=\$(... | grep || true) pattern" {
  # Create a test script with safe pattern
  cat > "$RITE_TEST_ROOT/safe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This is safe - has || true
RESULT=$(echo "foo" | grep "bar" || true)
echo "Result: $RESULT"
EOF

  # Run the script - should succeed with empty result
  run bash "$RITE_TEST_ROOT/safe.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Result:" ]]
}

@test "unsafe pattern silently kills script (demonstrates the bug)" {
  # Create a test script WITHOUT || true
  cat > "$RITE_TEST_ROOT/unsafe-demo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Starting..."
RESULT=$(echo "foo" | grep "bar")
echo "This line should never print"
echo "Result: $RESULT"
EOF

  # Run the script - should fail
  run bash "$RITE_TEST_ROOT/unsafe-demo.sh"

  # Script dies silently (exit 1, no error message from grep in a pipe)
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Starting..." ]]
  [[ ! "$output" =~ "This line should never print" ]]
}

@test "safe pattern continues gracefully when grep finds no match" {
  # Create a test script WITH || true
  cat > "$RITE_TEST_ROOT/safe-demo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Starting..."
RESULT=$(echo "foo" | grep "bar" || true)
echo "Continued after grep"
echo "Result: ${RESULT:-empty}"
EOF

  # Run the script - should succeed
  run bash "$RITE_TEST_ROOT/safe-demo.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Starting..." ]]
  [[ "$output" =~ "Continued after grep" ]]
  [[ "$output" =~ "Result: empty" ]]
}

@test "lint rule detects multiline unsafe pattern" {
  # Create a test script with multiline unsafe pattern in a location the linter scans
  cat > "$RITE_LINT_TEST_DIR/multiline-unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(git worktree list | \
  grep "pattern")
echo "Result: $RESULT"
EOF

  # Run the lint rule
  cd "$BATS_TEST_DIRNAME/../.."  # Project root (tests/regression/ → project root)
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
}

@test "lint rule allows multiline safe pattern" {
  # Create a test script with multiline safe pattern
  cat > "$RITE_TEST_ROOT/multiline-safe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(git worktree list | \
  grep "pattern" || true)
echo "Result: $RESULT"
EOF

  # Verify the safe script runs
  # (We can't run git worktree list in the test, but bash parsing should work)
  run bash -n "$RITE_TEST_ROOT/multiline-safe.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Boundary tests: Rule 8 AWK lookahead flush at file boundaries
#
# The AWK program uses a pending-line buffer: when a triggering line is found
# it sets pending_line=FNR, then resolves on the NEXT line.  Three flush paths
# exist and each must be exercised:
#
#   1. FNR == 1 (start of next file) — flushes pending from previous file
#   2. END block                     — flushes pending from last/only file
#   3. Same file, next line has guard — clears pending without printing
#
# The old per-file sed lookahead behaved identically (sed returned empty string
# for next_line when the trigger was on the last line; no guard = violation).
# These tests lock in that behavioral equivalence for the AWK replacement.
# ---------------------------------------------------------------------------

@test "Rule 8 boundary: trigger on last line of file fires violation (END block)" {
  # Unsafe pattern on the very last line — no next line to resolve the lookahead.
  # The AWK END block must flush pending_line and fire the violation.
  cat > "$RITE_LINT_TEST_DIR/r8-last-line-unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "preamble"
RESULT=$(echo "data" | grep "pattern")
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "r8-last-line-unsafe.sh" ]]
}

@test "Rule 8 boundary: safe pattern on last line of file — no violation" {
  # Safe pattern (|| true) on the very last line — no violation expected.
  # Use RITE_LINT_EXTRA_DIRS with a temp dir outside lib/ to avoid Rule 16
  # (MISSING_RESOURCE_GUARD) firing on the fixture itself.
  local _safe_dir="${BATS_TEST_TMPDIR}/r8-safe-boundary"
  mkdir -p "$_safe_dir"
  cat > "$_safe_dir/r8-last-line-safe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "preamble"
RESULT=$(echo "data" | grep "pattern" || true)
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_safe_dir"
  run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [[ ! "$output" =~ "r8-last-line-safe.sh" ]]
}

@test "Rule 8 boundary: single-line file with unsafe trigger fires violation" {
  # File has exactly one line (the trigger itself).
  # AWK: FNR==1 fires (nothing pending yet), then main block sets pending_line=1.
  # END block must flush and fire the violation.
  cat > "$RITE_LINT_TEST_DIR/r8-single-line-unsafe.sh" <<'EOF'
RESULT=$(echo "data" | grep "pattern")
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "r8-single-line-unsafe.sh" ]]
}

@test "Rule 8 boundary: trigger on last line of first file fires via FNR==1 of next file" {
  # When AWK processes multiple files, a pending trigger from the last line of
  # file N must be flushed at FNR==1 of file N+1 (not silently dropped).
  # Inject two fixtures; the linter scans both in one AWK pass.
  cat > "$RITE_LINT_TEST_DIR/r8-multi-file-a.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(echo "data" | grep "pattern")
EOF
  # Second file is clean — present only to force the multi-file AWK pass
  cat > "$RITE_LINT_TEST_DIR/r8-multi-file-b.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "clean file"
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  # Violation must reference the first file, not the second
  [[ "$output" =~ "r8-multi-file-a.sh" ]]
}

@test "Rule 8 boundary: multiline pattern where guard is on line after last trigger line" {
  # Two-line multiline pattern: trigger on line N, guard (|| true) on line N+1.
  # This is the normal multiline-safe case but ensures the lookahead resolves
  # correctly when it is also the end of the file.
  # Use RITE_LINT_EXTRA_DIRS with a temp dir outside lib/ to avoid Rule 16
  # (MISSING_RESOURCE_GUARD) firing on the fixture itself.
  local _safe_dir="${BATS_TEST_TMPDIR}/r8-multiline-boundary"
  mkdir -p "$_safe_dir"
  cat > "$_safe_dir/r8-multiline-guard-at-eof.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(echo "data" | \
  grep "pattern" || true)
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_safe_dir"
  run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [[ ! "$output" =~ "r8-multiline-guard-at-eof.sh" ]]
}

@test "codebase has zero remaining unsafe patterns" {
  cd "$(dirname "$BATS_TEST_DIRNAME")"

  # Search for patterns that look unsafe: VAR=$(... | grep ...) without || true on same line
  # This finds grep in command substitution, then filters out safe patterns
  run bash -c 'grep -rn "=\$(.*| grep" lib/ bin/ 2>/dev/null | grep -v "|| true\||| echo\|: \\\$?" || true'

  # For each match, verify it's safe via one of these patterns:
  # 1. Has || true somewhere in the next 10 lines (handles multiline)
  # 2. Pipes to head/tail which always succeeds (grep | head is safe)
  if [ -n "$output" ]; then
    while IFS=: read -r file line rest; do
      # Get a reasonable context window for multiline patterns
      context=$(sed -n "${line},$((line + 10))p" "$file" 2>/dev/null || true)

      # Check if pattern is safe: has || true OR pipes to head/tail
      if echo "$context" | grep -q '|| true'; then
        # Safe: has || true
        continue
      elif echo "$context" | grep -q '| head\|| tail'; then
        # Safe: pipes to head/tail which always succeed
        continue
      else
        fail "UNSAFE pattern without safety guard found at ${file}:${line}"
      fi
    done <<< "$output"
  fi

  # Test passes if all matches are verified safe
  [ "$status" -eq 0 ]
}
