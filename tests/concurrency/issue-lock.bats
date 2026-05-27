#!/usr/bin/env bats
# tests/concurrency/issue-lock.bats - Per-issue locking tests

setup() {
  # Create temporary test environment
  export TEST_DIR="$(mktemp -d)"
  export RITE_PROJECT_ROOT="$TEST_DIR"
  export RITE_DATA_DIR="$TEST_DIR/.rite"
  export RITE_LOCK_DIR="$RITE_DATA_DIR/locks"
  export RITE_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"

  mkdir -p "$RITE_DATA_DIR"
  mkdir -p "$RITE_LOCK_DIR"

  # Source the lock utilities
  source "$RITE_LIB_DIR/utils/issue-lock.sh"
}

teardown() {
  # Clean up test environment
  rm -rf "$TEST_DIR"
}

@test "acquire_issue_lock succeeds when no lock exists" {
  run acquire_issue_lock 42
  [ "$status" -eq 0 ]
  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]
  [ -f "$RITE_LOCK_DIR/issue-42.lock/pid" ]

  # Verify PID is correct
  local lock_pid
  lock_pid=$(cat "$RITE_LOCK_DIR/issue-42.lock/pid")
  [ "$lock_pid" = "$$" ]
}

@test "acquire_issue_lock fails when lock held by live process" {
  # First process acquires lock
  acquire_issue_lock 42

  # Second process (in subshell) tries to acquire same lock
  run bash -c "source '$RITE_LIB_DIR/utils/issue-lock.sh'; acquire_issue_lock 42"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "already being processed" ]]
}

@test "acquire_issue_lock reclaims stale lock from dead process" {
  # Create a lock with a fake (dead) PID
  mkdir -p "$RITE_LOCK_DIR/issue-42.lock"
  echo "99999" > "$RITE_LOCK_DIR/issue-42.lock/pid"

  # Should reclaim the stale lock
  run acquire_issue_lock 42
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Reclaiming stale lock" ]]

  # Verify lock now has our PID
  local lock_pid
  lock_pid=$(cat "$RITE_LOCK_DIR/issue-42.lock/pid")
  [ "$lock_pid" = "$$" ]
}

@test "acquire_issue_lock reclaims lock without PID file" {
  # Create a lock directory without PID file (crashed between mkdir and write)
  mkdir -p "$RITE_LOCK_DIR/issue-42.lock"

  # Should reclaim the broken lock
  run acquire_issue_lock 42
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Reclaiming stale lock" ]]

  # Verify lock now has our PID
  [ -f "$RITE_LOCK_DIR/issue-42.lock/pid" ]
}

@test "release_issue_lock removes lock directory" {
  acquire_issue_lock 42
  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]

  release_issue_lock 42
  [ ! -d "$RITE_LOCK_DIR/issue-42.lock" ]
}

@test "release_issue_lock only removes own lock (PID check)" {
  # Create a lock with different PID
  mkdir -p "$RITE_LOCK_DIR/issue-42.lock"
  echo "99999" > "$RITE_LOCK_DIR/issue-42.lock/pid"

  # Try to release - should not remove (not our lock)
  release_issue_lock 42
  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]

  # Verify PID unchanged
  local lock_pid
  lock_pid=$(cat "$RITE_LOCK_DIR/issue-42.lock/pid")
  [ "$lock_pid" = "99999" ]
}

@test "concurrent rite invocations - one succeeds, one exits 1" {
  skip "Integration test - requires full rite setup"

  # This test would require a full rite environment with GitHub API mocking
  # The acceptance criteria call for spawning two `rite 999 --auto` processes
  # and verifying only one proceeds. This is better tested manually or in
  # a dedicated integration test suite.
}

@test "multiple issues can be locked simultaneously" {
  acquire_issue_lock 42
  acquire_issue_lock 43

  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]
  [ -d "$RITE_LOCK_DIR/issue-43.lock" ]

  release_issue_lock 42
  release_issue_lock 43

  [ ! -d "$RITE_LOCK_DIR/issue-42.lock" ]
  [ ! -d "$RITE_LOCK_DIR/issue-43.lock" ]
}

@test "lock directory is created if missing" {
  # Remove lock directory
  rm -rf "$RITE_LOCK_DIR"

  # Should create it automatically
  run acquire_issue_lock 42
  [ "$status" -eq 0 ]
  [ -d "$RITE_LOCK_DIR" ]
  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]
}
