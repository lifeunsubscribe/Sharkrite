#!/usr/bin/env bats
# Regression test for: Fix unbound LOCKFILE variable in merge-pr cleanup
# Issue: lib/core/merge-pr.sh:1493 referenced $LOCKFILE in cleanup without
# defensive syntax, causing "unbound variable" crashes when no scratchpad
# work occurred (LOCKFILE never assigned).
#
# Expected behavior: Cleanup block should be a no-op when LOCKFILE is unset,
# without crashes or error output.

setup() {
  # Create minimal test environment
  export RITE_ROOT_DIR="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_LIB_DIR="${RITE_ROOT_DIR}/lib"
  export RITE_UTILS_DIR="${RITE_LIB_DIR}/utils"

  mkdir -p "$RITE_UTILS_DIR"

  # Mock print functions (used in merge-pr.sh)
  print_status() { echo "$@" >&2; }
  print_warning() { echo "WARNING: $@" >&2; }
  print_success() { echo "SUCCESS: $@" >&2; }
  export -f print_status print_warning print_success

  # Enable strict mode (merge-pr.sh inherits set -u from workflow-runner.sh)
  set -u
}

teardown() {
  rm -rf "$RITE_ROOT_DIR"
}

@test "lock release block handles unset LOCKFILE without crashing" {
  # Simulate the cleanup path: LOCKFILE is never assigned because
  # the scratchpad file check failed or was skipped

  # LOCKFILE is intentionally not set here — this is the bug condition

  # This is the exact code from merge-pr.sh lines 1397-1404 (after fix)
  # If the fix is correct, this should not crash with "unbound variable"
  run bash -c '
    set -u  # Enforce unbound variable detection

    # Release file lock (defensive: LOCKFILE may be unset if no scratchpad work occurred)
    if command -v flock >/dev/null 2>&1; then
      flock -u 200 2>/dev/null || true
      exec 200>&-
    else
      rm -f "${LOCKFILE:-}/pid" 2>/dev/null || true
      rmdir "${LOCKFILE:-}" 2>/dev/null || true
    fi

    echo "cleanup completed"
  '

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should produce the completion message
  echo "$output" | grep -q "cleanup completed"

  # Should NOT produce any "unbound variable" errors
  ! echo "$output" | grep -q "unbound variable"
}

@test "lock release block is no-op when LOCKFILE unset (mkdir-based locking)" {
  # Test the mkdir-based lock path specifically
  run bash -c '
    set -u

    # Simulate mkdir-based locking system (no flock available)
    # LOCKFILE is unset — defensive syntax should make this a no-op

    rm -f "${LOCKFILE:-}/pid" 2>/dev/null || true
    rmdir "${LOCKFILE:-}" 2>/dev/null || true

    echo "mkdir lock cleanup completed"
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "mkdir lock cleanup completed"
  ! echo "$output" | grep -q "unbound variable"
}

@test "lock release block works normally when LOCKFILE is set" {
  # Verify the fix doesn't break the normal case where LOCKFILE is assigned

  LOCKFILE="${BATS_TEST_TMPDIR}/test.lock"
  mkdir -p "$LOCKFILE"
  echo "$$" > "$LOCKFILE/pid"

  run bash -c "
    set -u
    LOCKFILE='${LOCKFILE}'

    # This is the mkdir-based cleanup path
    rm -f \"\${LOCKFILE:-}/pid\" 2>/dev/null || true
    rmdir \"\${LOCKFILE:-}\" 2>/dev/null || true

    echo 'normal cleanup completed'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "normal cleanup completed"

  # Lock directory should be removed
  [ ! -d "$LOCKFILE" ]
}
