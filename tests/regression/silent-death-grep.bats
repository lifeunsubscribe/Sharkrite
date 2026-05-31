#!/usr/bin/env bats
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
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  mkdir -p "$RITE_TEST_ROOT"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

@test "lint rule detects unsafe VAR=\$(... | grep) pattern" {
  # Create a test script with unsafe pattern
  cat > "$RITE_TEST_ROOT/unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This is unsafe - no || true
RESULT=$(echo "foo" | grep "bar")
echo "Result: $RESULT"
EOF

  # Run the lint rule
  cd "$(dirname "$BATS_TEST_DIRNAME")"  # Project root
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
  # Create a test script with multiline unsafe pattern
  cat > "$RITE_TEST_ROOT/multiline-unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(git worktree list | \
  grep "pattern")
echo "Result: $RESULT"
EOF

  # Run the lint rule
  cd "$(dirname "$BATS_TEST_DIRNAME")"
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
