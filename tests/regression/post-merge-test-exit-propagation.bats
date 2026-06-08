#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/post-merge-verify.sh
# Regression test for: Fix tee'd pipeline test_exit in post-merge-verify
#
# Bug: post-merge-verify.sh used `$?` after a pipeline (`... | sed`) without
# pipefail enabled, which captured sed's exit code (always 0), not the test
# command's exit code. This allowed failing tests to be silently reported as
# passing at the merge gate.
#
# Fix: Enable `set -o pipefail` at the top of the script so that $? after
# a pipeline captures the first failing command's exit code, not the last
# command in the pipeline.

setup() {
  # Create minimal test environment
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_PROJECT_ROOT="$RITE_TEST_ROOT"
  export RITE_LIB_DIR="${RITE_TEST_ROOT}/lib"
  mkdir -p "$RITE_LIB_DIR/utils"

  # Create test worktree
  export TEST_WORKTREE="${RITE_TEST_ROOT}/test-wt"
  mkdir -p "$TEST_WORKTREE"

  # Stub config.sh (required by post-merge-verify.sh)
  cat > "$RITE_LIB_DIR/utils/config.sh" <<'CONFIG_EOF'
#!/bin/bash
RITE_LIB_DIR="${RITE_LIB_DIR}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
RITE_SKIP_TESTS="${RITE_SKIP_TESTS:-false}"
RITE_TEST_CMD="${RITE_TEST_CMD:-}"
CONFIG_EOF

  # Copy actual post-merge-verify.sh from the real repo
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/utils/post-merge-verify.sh" "$RITE_LIB_DIR/utils/"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

@test "verify_post_merge returns 0 when test command exits 0" {
  # Create a fake test command that succeeds
  export RITE_TEST_CMD="exit 0"

  # Source the script
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Run verify_post_merge
  run verify_post_merge "$TEST_WORKTREE"

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]
}

@test "verify_post_merge returns 1 when test command exits 1 (critical regression guard)" {
  # Create a fake test command that fails
  export RITE_TEST_CMD="exit 1"

  # Source the script
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Skip the "check if main is broken" logic by stubbing git commands
  # We want to test only the exit code propagation, not the fallback logic
  function git() {
    if [[ "$*" == *"worktree add"* ]]; then
      # Fail worktree creation so main-check is skipped
      return 1
    fi
    # Pass through other git commands to real git
    command git "$@"
  }
  export -f git

  # Run verify_post_merge - should detect the failure
  run verify_post_merge "$TEST_WORKTREE"

  # Should fail (exit 1) because test_exit should be 1 from our stubbed command
  [ "$status" -eq 1 ]

  # Verify the error message indicates test failure
  [[ "$output" == *"Post-merge verification FAILED"* ]] || \
  [[ "$output" == *"tests now fail"* ]]
}

@test "verify_post_merge propagates exit code through tee'd pipeline with sed" {
  # This is the most specific test for the bug: verify that exit codes
  # propagate correctly through the exact pipeline pattern that was broken:
  # ( ... eval "$test_cmd" ) 2>&1 | sed 's/^/  /' >&2 || test_exit=$?

  # Create a test command that exits with a specific code
  export RITE_TEST_CMD="exit 42"

  # Source the script
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Stub git to skip main-check fallback
  function git() {
    if [[ "$*" == *"worktree add"* ]]; then
      return 1
    fi
    command git "$@"
  }
  export -f git

  # Run verify_post_merge
  run verify_post_merge "$TEST_WORKTREE"

  # Should fail (exit 1) - verify_post_merge converts any non-zero to 1
  [ "$status" -eq 1 ]

  # The key assertion: if the old bug existed (no pipefail), sed would have
  # returned 0 and test_exit would be 0, causing verify_post_merge to return 0.
  # With the fix (pipefail enabled), $? after the pipeline captures exit 42
  # from the test command, causing verify_post_merge to return 1.
}

@test "pipefail ensures \$? captures first failing command in pipeline" {
  # Verify that with pipefail enabled, $? after a pipeline captures the exit
  # code of the first failing command, not the last command in the pipeline.
  # This is the mechanism that makes exit code propagation work correctly.

  # Enable pipefail (matching post-merge-verify.sh)
  set -o pipefail

  # Run a command with no pipeline
  (exit 17) || EXIT_CODE=$?

  # Should capture the exit code correctly
  [ "$EXIT_CODE" -eq 17 ]

  # Run a command with a pipeline (first command fails, second succeeds)
  (exit 23) | cat >/dev/null || EXIT_CODE=$?

  # With pipefail, should capture the first command's exit code, not cat's
  [ "$EXIT_CODE" -eq 23 ]
}

@test "set -o pipefail is enabled in post-merge-verify.sh" {
  # Verify that pipefail is set to ensure pipeline failures propagate

  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Check if pipefail is enabled by examining shell options
  # The 'set -o' command lists all shell options and their states
  run bash -c "source '$RITE_LIB_DIR/utils/post-merge-verify.sh' && set -o | grep pipefail"

  # Should show "pipefail on"
  [[ "$output" == *"pipefail"*"on"* ]]
}
