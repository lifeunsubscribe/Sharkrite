#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh
# tests/concurrency/session-state-race.bats - Session state file race condition tests
#
# Tests that concurrent updates to SESSION_STATE_FILE don't corrupt JSON or lose data.
# These tests verify fixes for issue #8 (session state races).
#
# Previously the "concurrent blocker approval additions" test bypassed the real
# add_approved_blocker() function and used inline jq read-modify-write, which
# tested hand-rolled code rather than the actual implementation. When
# session-tracker.sh gets proper locking, the old test would not verify it.
#
# This version calls add_approved_blocker() and has_approved_blocker() directly.
#
# NOTE: The "EXPECTED FAILURE" escape hatches (return 0) that existed before
# issue #8's locking landed have been removed.  These are now hard-failure
# assertions — if session-state locking regresses, these tests WILL fail
# (which is the point).  See issue-lock.bats for the same pattern.

load '../helpers/setup.bash'

setup() {
  # Skip on bash 3.2 (macOS system bash). Moved from setup_file() — skip inside
  # setup_file() requires bats >=1.5.0; skip inside setup() is universally supported.
  # Barrier sync + subshell spawning relies on bash 4+ performance:
  # bash 3.2 startup is 50-150ms per subshell vs ~10ms for bash 4+, so
  # concurrent subshells can't reliably reach the barrier within the timeout
  # on a busy macOS dev machine, producing false failures unrelated to the
  # session-state race behavior under test.
  # On Homebrew bash 4+ (macOS) and Linux CI (bash 4+ default), tests run fully.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (detected bash ${BASH_VERSION}). Install via: brew install bash"
  fi

  setup_test_tmpdir

  # Set up environment for session tracking
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export SESSION_STATE_FILE="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state.json"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  # Source the session tracker
  source "$RITE_LIB_DIR/utils/session-tracker.sh"

  # Initialize session
  init_session "unsupervised"

  # Create barrier directory for synchronization
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# Barrier synchronization helper
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$BASHPID"

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

@test "concurrent session state updates - no JSON corruption" {
  # Test that concurrent update_session() calls don't corrupt the JSON
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Spawn N processes that each update a different field
  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "session_update_test" "$num_processes" || exit 1

      # Each process updates a different counter
      # Re-source to get the function in this subshell
      source "$RITE_LIB_DIR/utils/session-tracker.sh"

      # Update a field (this will race with other processes)
      case $i in
        1) update_session "issues_completed" "1" ;;
        2) update_session "issues_failed" "1" ;;
        3) update_session "current_issue" "42" ;;
        4) update_session "issues_completed" "2" ;;
        5) update_session "issues_completed" "3" ;;
      esac

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all processes completed
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done

  # Verify JSON is still valid (not corrupted)
  # Issue #8's session-state locking must prevent concurrent write corruption.
  run jq empty "$SESSION_STATE_FILE"
  [ "$status" -eq 0 ] || {
    echo "FAIL: JSON corrupted by concurrent writes — session-state locking (issue #8) regressed"
    cat "$SESSION_STATE_FILE"
    return 1
  }

  # Verify structure is intact
  jq -e '.start_time' "$SESSION_STATE_FILE" >/dev/null
  jq -e '.mode' "$SESSION_STATE_FILE" >/dev/null
  jq -e '.last_update' "$SESSION_STATE_FILE" >/dev/null
}

@test "concurrent blocker approval additions via add_approved_blocker - no lost approvals" {
  # Test that concurrent blocker approvals via add_approved_blocker() don't lose data.
  # Previously this test used inline jq read-modify-write, which tested hand-rolled
  # code rather than the actual add_approved_blocker() implementation. When
  # session-tracker.sh gets proper locking, the old test would not verify it.
  #
  # This version calls add_approved_blocker() directly and verifies has_approved_blocker()
  # returns true for all approvals afterwards.
  local num_processes=4
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "approval_test" "$num_processes" || exit 1

      source "$RITE_LIB_DIR/utils/session-tracker.sh"

      # Each process calls the real add_approved_blocker() (races without locking)
      add_approved_blocker "issue-${i}" "blocker-${i}"

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all processes exited successfully
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done

  # Verify JSON is still valid
  # Issue #8's locking must prevent JSON corruption during concurrent approval additions.
  jq empty "$SESSION_STATE_FILE" 2>/dev/null || {
    echo "FAIL: JSON corruption in blocker approvals — session-state locking (issue #8) regressed"
    cat "$SESSION_STATE_FILE" >&2
    return 1
  }

  # Verify approvals are present using has_approved_blocker() (the real read-back path)
  local found_count=0
  for i in $(seq 1 $num_processes); do
    if has_approved_blocker "issue-${i}" "blocker-${i}"; then
      found_count=$((found_count + 1))
    fi
  done

  # Issue #8's locked read-modify-write must prevent lost approvals.
  [ "$found_count" -eq "$num_processes" ] || {
    echo "FAIL: Only $found_count/$num_processes approvals saved — concurrent read-modify-write race (issue #8) regressed"
    return 1
  }
}

@test "session initialization while updates in progress" {
  # Test the race between init_session and update_session
  # One process initializes while others update
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Process 1: repeatedly update
  (
    source "$RITE_LIB_DIR/utils/session-tracker.sh"
    wait_at_barrier "init_race_test" "3" || exit 1

    # Start updating immediately
    for i in {1..5}; do
      update_session "issues_completed" "$i"
    done

    echo $? > "$exit_codes_dir/process_1.exit"
  ) &

  # Process 2: reinitialize in the middle
  (
    source "$RITE_LIB_DIR/utils/session-tracker.sh"
    wait_at_barrier "init_race_test" "3" || exit 1

    # Wait for process 1 to start (barrier on first update)
    wait_at_barrier "init_race_update_started" "2" || exit 1
    init_session "supervised"  # This will overwrite the file

    echo $? > "$exit_codes_dir/process_2.exit"
  ) &

  # Process 3: more updates
  (
    source "$RITE_LIB_DIR/utils/session-tracker.sh"
    wait_at_barrier "init_race_test" "3" || exit 1

    # Signal that updates have started
    wait_at_barrier "init_race_update_started" "2" || exit 1
    update_session "issues_failed" "1"

    echo $? > "$exit_codes_dir/process_3.exit"
  ) &

  wait

  # Verify JSON is still valid at the end.
  # Issue #8's locking makes init_session an upsert (no-op if file already exists),
  # preventing concurrent init from clobbering in-progress updates.
  jq empty "$SESSION_STATE_FILE" 2>/dev/null || {
    echo "FAIL: JSON corrupted by init/update race — session-state locking (issue #8) regressed"
    cat "$SESSION_STATE_FILE" >&2
    return 1
  }

  # Verify basic structure exists
  jq -e '.mode' "$SESSION_STATE_FILE" >/dev/null
}

@test "high-concurrency session updates - stress test" {
  # Stress test: 10 processes, each doing 10 updates
  local num_processes=10
  local updates_per_process=10
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for proc in $(seq 1 $num_processes); do
    (
      source "$RITE_LIB_DIR/utils/session-tracker.sh"
      wait_at_barrier "stress_test" "$num_processes" || exit 1

      # Each process does rapid updates
      for i in $(seq 1 $updates_per_process); do
        update_session "issues_completed" "$((proc * 100 + i))" 2>/dev/null || true
      done

      echo $? > "$exit_codes_dir/process_${proc}.exit"
    ) &
  done

  wait

  # Primary check: JSON must not be corrupted.
  # Issue #8's session-state locking must hold even under high concurrency (10×10).
  run jq empty "$SESSION_STATE_FILE"
  [ "$status" -eq 0 ] || {
    echo "FAIL: JSON corrupted under high concurrency — session-state locking (issue #8) regressed"
    echo "File contents:"
    cat "$SESSION_STATE_FILE" || echo "(file unreadable)"
    return 1
  }

  # Secondary check: verify file has expected structure
  local has_start_time=$(jq -e '.start_time' "$SESSION_STATE_FILE" >/dev/null 2>&1 && echo "yes" || echo "no")
  local has_mode=$(jq -e '.mode' "$SESSION_STATE_FILE" >/dev/null 2>&1 && echo "yes" || echo "no")

  [ "$has_start_time" = "yes" ] && [ "$has_mode" = "yes" ]
}

@test "session state file doesn't exist - concurrent creation" {
  # Test race when session state file is missing
  rm -f "$SESSION_STATE_FILE"

  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      source "$RITE_LIB_DIR/utils/session-tracker.sh"
      wait_at_barrier "creation_test" "$num_processes" || exit 1

      # All processes try to create/update at once
      if [ ! -f "$SESSION_STATE_FILE" ]; then
        init_session "unsupervised"
      fi
      update_session "current_issue" "$i"

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify file exists and is valid JSON
  [ -f "$SESSION_STATE_FILE" ]

  jq empty "$SESSION_STATE_FILE" 2>/dev/null || {
    echo "FAIL: JSON corrupted during concurrent creation — session-state locking (issue #8) regressed"
    cat "$SESSION_STATE_FILE" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test: parallel increment_completed — no lost increments
#
# Acceptance criterion (issue #26): spawn 5 parallel workers each calling
# increment_completed; assert final issues_completed == 5.
#
# This validates the locked read-modify-write in increment_completed — the
# actual race-safe path. init_session is called ONCE up front (matching the
# real batch orchestrator, batch-process-issues.sh:528, which inits once and
# lets per-issue workers increment). The earlier "parallel init_session must be
# an upsert" premise was dropped: init_session deliberately RESETS the
# per-invocation counters when the file already exists (session-tracker.sh:212-240,
# justified by the issue #283 zombie-file fix), so parallel init_session calls
# legitimately clobber increments by design — that is not the contract under test.
# ---------------------------------------------------------------------------
@test "parallel increment_completed - no lost increments (issue #26)" {
  # Initialise the session file ONCE up front, as the batch orchestrator does.
  rm -f "$SESSION_STATE_FILE"
  init_session "unsupervised"

  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      source "$RITE_LIB_DIR/utils/session-tracker.sh"

      # All 5 processes converge at the barrier so they race for real
      wait_at_barrier "init_increment_race" "$num_processes" || exit 1

      # Each process simulates a per-issue worker in one batch:
      # increment_completed holds the lock across read-modify-write, so
      # concurrent increments must not be lost.
      increment_completed

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # All processes must have completed without error
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ] || {
      echo "FAIL: process $i did not produce an exit code file" >&2
      return 1
    }
    local exit_code
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ] || {
      echo "FAIL: process $i exited with code $exit_code" >&2
      return 1
    }
  done

  # JSON must be valid
  jq empty "$SESSION_STATE_FILE" || {
    echo "FAIL: JSON corrupted after parallel init+increment" >&2
    cat "$SESSION_STATE_FILE" >&2
    return 1
  }

  # The count must be exactly num_processes — no increment was lost to a race
  local final_count
  final_count=$(jq -r '.issues_completed' "$SESSION_STATE_FILE")

  [ "$final_count" -eq "$num_processes" ] || {
    echo "FAIL: issues_completed=${final_count}, expected ==${num_processes}" >&2
    echo "      increment_completed's locked read-modify-write lost a concurrent increment" >&2
    return 1
  }
}
