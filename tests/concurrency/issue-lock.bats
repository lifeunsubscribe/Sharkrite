#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/issue-lock.sh
# tests/concurrency/issue-lock.bats - Per-issue locking tests
#
# Tests that per-issue locking prevents duplicate work on the same issue.
# Multiple processes should not be able to work on the same issue simultaneously.
# These tests verify fixes for issue #9 (per-issue locking).
#
# Issue #9 = "Add per-issue lock to prevent concurrent rite collisions" (CLOSED).
# Implemented in lib/utils/issue-lock.sh via atomic mkdir-based locking.
# Not issue #8 ("Make empty Claude assessment fail loud") — different subsystem.
#
# NOTE: The "EXPECTED FAILURE" escape hatches that were here before issue #9 landed
# have been removed.  These are now hard-failure assertions — if locking regresses,
# these tests WILL fail (which is the point).
#
# WHY these are not flaky: issue-lock.sh uses `mkdir` for acquisition, which is
# atomic on POSIX filesystems.  Exactly one concurrent caller wins the mkdir race;
# the rest see EEXIST and either wait or fail.  The barrier helper ensures all
# subprocesses are spawned before any of them attempts to acquire, maximising the
# chance of a real race.  A `success_count != 1` result therefore indicates a
# genuine atomicity regression, not a timing artifact.

load '../helpers/setup.bash'

setup() {
  # Skip on bash 3.2 (macOS system bash). Moved from setup_file() — skip inside
  # setup_file() requires bats >=1.5.0; skip inside setup() is universally supported.
  # Barrier sync + subshell spawning relies on bash 4+ performance:
  # bash 3.2 startup is 50-150ms per subshell vs ~10ms for bash 4+, so
  # 5 concurrent subshells can't reach the barrier before a 10s timeout
  # on a busy macOS dev machine, producing false failures unrelated to
  # the locking behavior under test.
  # On Homebrew bash 4+ (macOS) and Linux CI (bash 4+ default), tests run fully.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (detected bash ${BASH_VERSION}). Install via: brew install bash"
  fi

  setup_test_tmpdir

  # Set up environment for issue locking
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/locks"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"
  mkdir -p "$RITE_LOCK_DIR"

  # Create barrier directory for synchronization
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"

  # Source the lock utilities if they exist
  if [ -f "$RITE_LIB_DIR/utils/issue-lock.sh" ]; then
    source "$RITE_LIB_DIR/utils/issue-lock.sh"
  fi
}

teardown() {
  teardown_test_tmpdir
}

# Barrier synchronization helper
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  touch "$pid_file"

  local count=0
  local timeout=0
  # 100 iterations × 0.1s = 10s. Bumped from 5s to give bash 4+ subshells
  # enough headroom on a loaded macOS dev machine.
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 100 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done

  if [ "$timeout" -ge 100 ]; then
    echo "ERROR: Barrier timeout waiting for $expected_count processes (got $count)" >&2
    return 1
  fi
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
  # Create a lock with a provably-dead PID (completed subshell — portable across
  # all Linux pid_max settings, unlike hardcoded 99999 / 99999999).
  mkdir -p "$RITE_LOCK_DIR/issue-42.lock"
  get_dead_pid > "$RITE_LOCK_DIR/issue-42.lock/pid"

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
  # Create a lock with a provably-dead PID that is NOT the current process.
  # Using get_dead_pid() (completed subshell) is portable across all Linux
  # pid_max settings — unlike hardcoded 99999 which can be a live PID on
  # systems with pid_max > 99999 (containers, custom kernel configs).
  local other_pid
  other_pid=$(get_dead_pid)
  mkdir -p "$RITE_LOCK_DIR/issue-42.lock"
  echo "$other_pid" > "$RITE_LOCK_DIR/issue-42.lock/pid"

  # Try to release - should not remove (not our lock)
  release_issue_lock 42
  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]

  # Verify PID unchanged
  local lock_pid
  lock_pid=$(cat "$RITE_LOCK_DIR/issue-42.lock/pid" || true)
  [ "$lock_pid" = "$other_pid" ]
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

@test "concurrent lock attempts - only one succeeds" {
  # Test: Multiple processes try to lock the same issue concurrently
  # Expected: Only one process gets the lock
  local issue_number=999
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "concurrent_lock_test" "$num_processes" || exit 1

      # All processes try to acquire the lock simultaneously
      acquire_issue_lock "$issue_number" >/dev/null 2>&1
      local result=$?

      echo "$result" > "$exit_codes_dir/process_${i}.exit"

      # Release lock if we got it
      if [ "$result" -eq 0 ]; then
        release_issue_lock "$issue_number"
      fi
    ) &
  done

  wait

  # Count how many processes got the lock
  local success_count=0
  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
      [ "$exit_code" -eq 0 ] && success_count=$((success_count + 1))
    fi
  done

  # Exactly one process should have gotten the lock.
  # Issue #9 (per-issue locking) landed — this is now a hard assertion.
  # mkdir atomicity guarantees exactly 1 winner.
  #
  # If you see this failure with success_count=0, the barrier timed out before
  # all subprocesses arrived — that is a test-scaffolding failure (slow machine),
  # NOT a regression in locking. The bash 4+ guard in setup() and the 10s
  # barrier timeout are the primary mitigations; if this still fires, check
  # system load rather than the lock implementation.
  [ "$success_count" -eq 1 ] || {
    echo "FAIL: $success_count processes got the lock (expected exactly 1)."
    echo "  success_count=0 → barrier timed out (test scaffolding failure, not a lock regression)"
    echo "  success_count>1 → mkdir is not atomic on this FS (genuine regression)"
    false
  }
}

@test "concurrent stale lock reclamation - race condition" {
  # Test: Multiple processes detect stale lock and try to reclaim
  # Expected: Only one succeeds in reclaiming
  local issue_number=888
  local num_processes=4
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Create a stale lock with a provably-dead PID (completed subshell — portable
  # across all Linux pid_max settings, unlike hardcoded 99999 / 99999999).
  mkdir -p "$RITE_LOCK_DIR/issue-${issue_number}.lock"
  get_dead_pid > "$RITE_LOCK_DIR/issue-${issue_number}.lock/pid"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "stale_reclaim_test" "$num_processes" || exit 1

      # All processes try to reclaim stale lock
      acquire_issue_lock "$issue_number" >/dev/null 2>&1
      local result=$?

      echo "$result" > "$exit_codes_dir/process_${i}.exit"

      # Release if we got it
      if [ "$result" -eq 0 ]; then
        release_issue_lock "$issue_number"
      fi
    ) &
  done

  wait

  # Count successes
  local success_count=0
  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
      [ "$exit_code" -eq 0 ] && success_count=$((success_count + 1))
    fi
  done

  # Only one should have reclaimed successfully.
  # Issue #9 (per-issue locking) landed — this is now a hard assertion.
  # Reclamation uses rm-then-mkdir; only one concurrent rm+mkdir sequence
  # can win the subsequent mkdir.
  #
  # If you see success_count=0, the barrier timed out (test scaffolding failure,
  # NOT a regression in the lock implementation). Check system load.
  [ "$success_count" -eq 1 ] || {
    echo "FAIL: $success_count processes reclaimed the stale lock (expected exactly 1)."
    echo "  success_count=0 → barrier timed out (test scaffolding failure, not a lock regression)"
    echo "  success_count>1 → stale-reclaim rm+mkdir sequence is not atomic (genuine regression)"
    false
  }
}

@test "multiple issues locked simultaneously by different processes" {
  # Test: Processes working on different issues can all hold locks
  # Expected: All processes succeed (different locks)
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "multi_issue_lock_test" "$num_processes" || exit 1

      # Each process locks a different issue
      local issue_num=$((500 + i))
      acquire_issue_lock "$issue_num" >/dev/null 2>&1
      local result=$?

      echo "$result" > "$exit_codes_dir/process_${i}.exit"

      # Hold lock briefly to ensure concurrency
      wait_at_barrier "locks_held" "$num_processes" || exit 1

      # Release
      release_issue_lock "$issue_num"
    ) &
  done

  wait

  # All processes should succeed (different issues = different locks)
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done
}
