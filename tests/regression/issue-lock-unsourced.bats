#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/issue-lock.sh
# Regression test for: Add RITE_LOCK_DIR default in issue-lock.sh
# Issue #69: lib/utils/issue-lock.sh referenced ${RITE_LOCK_DIR} but checked
# ${RITE_LIB_DIR} instead of ${RITE_LOCK_DIR} to decide whether to source config.sh.
# This caused "unbound variable" crashes when called from a context where
# RITE_LIB_DIR was set but RITE_LOCK_DIR was not.
#
# Expected behavior: issue-lock.sh should source config.sh when RITE_LOCK_DIR
# is unset, regardless of whether RITE_LIB_DIR is set.

setup() {
  # Create minimal test environment
  export RITE_ROOT_DIR="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_LIB_DIR="${RITE_ROOT_DIR}/lib"
  export RITE_UTILS_DIR="${RITE_LIB_DIR}/utils"
  export RITE_CORE_DIR="${RITE_LIB_DIR}/core"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="${BATS_TEST_TMPDIR}/test-project"
  export RITE_PROJECT_NAME="test-project"

  mkdir -p "$RITE_UTILS_DIR"
  mkdir -p "$RITE_CORE_DIR"
  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  # Copy the real config.sh and issue-lock.sh to test environment
  cp lib/utils/config.sh "$RITE_UTILS_DIR/"
  cp lib/utils/issue-lock.sh "$RITE_UTILS_DIR/"

  # Mock print functions (used by issue-lock.sh)
  print_status() { echo "$@" >&2; }
  print_warning() { echo "WARNING: $@" >&2; }
  print_error() { echo "ERROR: $@" >&2; }
  export -f print_status print_warning print_error
}

teardown() {
  rm -rf "$RITE_ROOT_DIR"
  rm -rf "$RITE_PROJECT_ROOT"
}

@test "issue-lock.sh sources config when RITE_LOCK_DIR is unset" {
  # This is the bug scenario: RITE_LIB_DIR is set (from a previous config.sh source)
  # but RITE_LOCK_DIR is not exported or was never set.
  # The old code checked RITE_LIB_DIR and skipped sourcing config.sh,
  # causing RITE_LOCK_DIR to remain unset.

  run bash -c "
    set -u  # Enforce unbound variable detection
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'

    # RITE_LOCK_DIR is intentionally not set — this triggers the bug in the old code

    # Source issue-lock.sh (should auto-source config.sh if RITE_LOCK_DIR is unset)
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    # Try to use the lock functions
    acquire_issue_lock 999
    release_issue_lock 999

    echo 'PASS: lock functions worked without crashing'
  "

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should produce the success message
  echo "$output" | grep -q "PASS: lock functions worked"

  # Should NOT produce any "unbound variable" errors
  ! echo "$output" | grep -q "unbound variable"
}

@test "issue-lock.sh works when config.sh already sourced" {
  # Verify the fix doesn't break the normal case where config.sh was already sourced

  run bash -c "
    set -u
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'

    # Source config.sh first (normal workflow path)
    source '${RITE_UTILS_DIR}/config.sh'

    # RITE_LOCK_DIR should now be set
    [ -n \"\${RITE_LOCK_DIR:-}\" ] || { echo 'ERROR: RITE_LOCK_DIR not set by config.sh'; exit 1; }

    # Source issue-lock.sh (should skip re-sourcing config since RITE_LOCK_DIR is set)
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    # Try to use the lock functions
    acquire_issue_lock 998
    release_issue_lock 998

    echo 'PASS: lock functions worked with pre-sourced config'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS: lock functions worked with pre-sourced config"
  ! echo "$output" | grep -q "unbound variable"
}

@test "acquire_issue_lock creates lock directory and PID file" {
  run bash -c "
    set -u
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    # Acquire lock
    acquire_issue_lock 997

    # Verify lock directory exists
    [ -d \"\${RITE_LOCK_DIR}/issue-997.lock\" ] || { echo 'Lock dir not created'; exit 1; }

    # Verify PID file exists
    [ -f \"\${RITE_LOCK_DIR}/issue-997.lock/pid\" ] || { echo 'PID file not created'; exit 1; }

    # Read PID
    cat \"\${RITE_LOCK_DIR}/issue-997.lock/pid\"

    # Cleanup
    release_issue_lock 997

    echo 'PASS: lock directory and PID file created correctly'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS: lock directory and PID file created correctly"
}

@test "release_issue_lock removes lock directory" {
  run bash -c "
    set -u
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    # Acquire and release lock
    acquire_issue_lock 996

    # Verify lock exists
    [ -d \"\${RITE_LOCK_DIR}/issue-996.lock\" ] || { echo 'Lock not acquired'; exit 1; }

    # Release lock
    release_issue_lock 996

    # Verify lock is removed
    [ ! -d \"\${RITE_LOCK_DIR}/issue-996.lock\" ] || { echo 'Lock not released'; exit 1; }

    echo 'PASS: lock released correctly'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS: lock released correctly"
}
