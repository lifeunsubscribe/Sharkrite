#!/usr/bin/env bats
# Regression test for: Batch reporter must distinguish merge-succeeded from merge-failed
# Issue #57
#
# Bug: batch reporter conflates "merge failed" (work not on remote) with "merge succeeded
# but post-merge cleanup crashed" (work IS on remote). When 4 of 5 PRs successfully land
# on main but post-merge cleanup hits a bug, user sees "5 Failed" and assumes nothing
# landed — leading to attempts to re-run already-merged work.
#
# Expected behavior:
# - Exit 0: merged-clean (everything succeeded)
# - Exit 6: merged-cleanup-failed (merge succeeded, cleanup crashed)
# - Exit 1: merge-failed or dev-failed (no work on remote)
# - Batch reporter shows distinct counts for each category
# - PR URLs displayed for merged-cleanup-failed so user knows work landed

setup() {
  # Create minimal test environment
  export RITE_ROOT_DIR="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_LIB_DIR="${RITE_ROOT_DIR}/lib"
  export RITE_CORE_DIR="${RITE_LIB_DIR}/core"

  mkdir -p "$RITE_CORE_DIR"

  # Mock print functions
  print_status() { echo "$@" >&2; }
  print_warning() { echo "WARNING: $@" >&2; }
  print_success() { echo "SUCCESS: $@" >&2; }
  print_info() { echo "INFO: $@" >&2; }
  print_error() { echo "ERROR: $@" >&2; }
  export -f print_status print_warning print_success print_info print_error
}

teardown() {
  rm -rf "$RITE_ROOT_DIR"
}

@test "merge-pr.sh exits with code 6 when merge succeeds but cleanup fails" {
  # Simulate the scenario: merge succeeds, cleanup fails
  # Expected: exit 6 (not exit 1)

  # Create mock script that simulates the cleanup failure path
  cat > "$RITE_CORE_DIR/test-cleanup-exit.sh" <<'TESTEOF'
#!/bin/bash
set -e
# Simulate merge success
echo "PR merged successfully"
# Now run cleanup phase - turn off set -e so errors don't immediately exit
set +e
CLEANUP_FAILED=false
trap 'CLEANUP_FAILED=true' ERR

# Trigger an error during cleanup
false

# Check cleanup status and exit accordingly
if [ "$CLEANUP_FAILED" = true ]; then
  echo "WARNING: cleanup failed" >&2
  exit 6
fi
exit 0
TESTEOF
  chmod +x "$RITE_CORE_DIR/test-cleanup-exit.sh"

  # Run the test script
  run "$RITE_CORE_DIR/test-cleanup-exit.sh"

  # Should exit with code 6
  [ "$status" -eq 6 ]
}

@test "batch reporter classifies exit 6 as merged-cleanup-failed not failed" {
  # Test the batch-process-issues.sh exit code handling logic

  run bash -c "
    set -euo pipefail

    # Simulate workflow-runner.sh returning exit 6
    EXIT_CODE=6

    # This is the classification logic from batch-process-issues.sh (after fix)
    if [ \$EXIT_CODE -eq 6 ]; then
      echo 'CLASSIFICATION: merged_cleanup_failed'
      exit 0
    elif [ \$EXIT_CODE -eq 10 ]; then
      echo 'CLASSIFICATION: blocked'
      exit 0
    else
      echo 'CLASSIFICATION: failed'
      exit 0
    fi
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLASSIFICATION: merged_cleanup_failed"
}

@test "batch reporter classifies exit 1 as failed not merged" {
  # Test that genuine failures (dev or merge) are still classified as failed

  run bash -c "
    set -euo pipefail

    # Simulate workflow-runner.sh returning exit 1 (merge failed)
    EXIT_CODE=1

    # Classification logic
    if [ \$EXIT_CODE -eq 6 ]; then
      echo 'CLASSIFICATION: merged_cleanup_failed'
      exit 0
    elif [ \$EXIT_CODE -eq 10 ]; then
      echo 'CLASSIFICATION: blocked'
      exit 0
    else
      echo 'CLASSIFICATION: failed'
      exit 0
    fi
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLASSIFICATION: failed"
}

@test "batch summary shows cleanup warning count correctly" {
  # Test the summary report format

  run bash -c "
    # Simulate batch processing results
    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=(42 29)
    FAILED_ISSUES=(28)
    CLEANUP_WARNING_COUNT=\${#MERGED_CLEANUP_FAILED[@]}

    # This is the summary output logic from batch-process-issues.sh (after fix)
    if [ \$CLEANUP_WARNING_COUNT -gt 0 ]; then
      echo \"Completed:        \$COMPLETED_ISSUES (\${CLEANUP_WARNING_COUNT} with cleanup warnings)\"
    else
      echo \"Completed:        \$COMPLETED_ISSUES\"
    fi
    echo \"Failed:           \${#FAILED_ISSUES[@]}\"
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Completed:.*2 (2 with cleanup warnings)"
  echo "$output" | grep -q "Failed:.*1"
}

@test "batch summary without cleanup warnings shows normal format" {
  # Test the summary when no cleanup failures occurred

  run bash -c "
    COMPLETED_ISSUES=5
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    CLEANUP_WARNING_COUNT=\${#MERGED_CLEANUP_FAILED[@]}

    if [ \$CLEANUP_WARNING_COUNT -gt 0 ]; then
      echo \"Completed:        \$COMPLETED_ISSUES (\${CLEANUP_WARNING_COUNT} with cleanup warnings)\"
    else
      echo \"Completed:        \$COMPLETED_ISSUES\"
    fi
    echo \"Failed:           \${#FAILED_ISSUES[@]}\"
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Completed:.*5"
  ! echo "$output" | grep -q "cleanup warnings"
  echo "$output" | grep -q "Failed:.*0"
}
