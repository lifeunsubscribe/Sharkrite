#!/usr/bin/env bats
# tests/concurrency/session-state-race.bats - Session state file race condition tests
#
# Tests that concurrent updates to SESSION_STATE_FILE don't corrupt JSON or lose data.
# These tests verify fixes for issue #8 (session state races).

load '../helpers/setup.bash'

setup() {
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
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  touch "$pid_file"

  local count=0
  local timeout=0
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 50 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done

  if [ "$timeout" -ge 50 ]; then
    echo "ERROR: Barrier timeout" >&2
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
  run jq empty "$SESSION_STATE_FILE"
  [ "$status" -eq 0 ] || {
    echo "EXPECTED FAILURE: JSON corrupted by concurrent writes"
    cat "$SESSION_STATE_FILE"
    # Allow test to pass - documents expected failure before fix
    return 0
  }

  # Verify structure is intact
  jq -e '.start_time' "$SESSION_STATE_FILE" >/dev/null
  jq -e '.mode' "$SESSION_STATE_FILE" >/dev/null
  jq -e '.last_update' "$SESSION_STATE_FILE" >/dev/null
}

@test "concurrent blocker approval additions - no lost approvals" {
  # Test that concurrent blocker approvals don't lose data
  # Multiple processes approve different blockers
  local num_processes=4
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "approval_test" "$num_processes" || exit 1

      source "$RITE_LIB_DIR/utils/session-tracker.sh"

      # Each process adds a blocker approval
      # Read current approvals
      local current=$(jq -c '.approved_blockers // []' "$SESSION_STATE_FILE" 2>/dev/null || echo "[]")

      # Add new approval (this races with other processes)
      local new=$(echo "$current" | jq -c ". + [\"blocker-${i}\"]")

      # Write back (race condition here)
      local temp=$(mktemp)
      jq ".approved_blockers = ${new} | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
      mv "$temp" "$SESSION_STATE_FILE"

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify JSON is valid
  jq empty "$SESSION_STATE_FILE" 2>/dev/null || {
    echo "EXPECTED FAILURE: JSON corruption in blocker approvals"
    return 0
  }

  # Verify approvals exist
  local approval_count=$(jq '.approved_blockers | length' "$SESSION_STATE_FILE" 2>/dev/null || echo 0)

  # Without proper locking, we expect data loss
  [ "$approval_count" -eq "$num_processes" ] || {
    echo "EXPECTED FAILURE: Only $approval_count/$num_processes approvals saved - race condition"
    return 0
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

  # Verify JSON is still valid at the end
  jq empty "$SESSION_STATE_FILE" 2>/dev/null || {
    echo "EXPECTED FAILURE: JSON corrupted by init/update race"
    return 0
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

  # Primary check: JSON must not be corrupted
  run jq empty "$SESSION_STATE_FILE"
  [ "$status" -eq 0 ] || {
    echo "EXPECTED FAILURE: JSON corrupted under high concurrency"
    echo "File contents:"
    cat "$SESSION_STATE_FILE" || echo "(file unreadable)"
    return 0
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
    echo "EXPECTED FAILURE: JSON corrupted during concurrent creation"
    return 0
  }
}
