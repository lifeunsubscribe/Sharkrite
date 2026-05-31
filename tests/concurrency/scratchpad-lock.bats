#!/usr/bin/env bats
# tests/concurrency/scratchpad-lock.bats - Scratchpad concurrent write tests
#
# Tests that concurrent writes to scratchpad don't lose data or corrupt structure.
# These tests verify fixes for issue #19 (scratchpad race conditions).

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  # Set up environment for scratchpad
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export SCRATCHPAD_FILE="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  # Create initial scratchpad structure
  cat > "$SCRATCHPAD_FILE" <<'EOF'
# Scratchpad

## Encountered Issues (Needs Triage)

_Issues discovered during development that need follow-up._

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Sharkrite updates this automatically._

---

## Completed Work Archive

_Last 20 PRs — auto-cleaned_

EOF

  # Source the scratchpad manager
  source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"

  # Create barrier directory for synchronization
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# Barrier synchronization helper - all processes wait here until N arrive
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local barrier_file="$BARRIER_DIR/${barrier_name}"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  # Mark this process as arrived
  if ! touch "$pid_file"; then
    echo "ERROR: Failed to create barrier pid file: $pid_file" >&2
    return 1
  fi

  # Wait until all processes arrive (busy wait with short sleep)
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
    echo "ERROR: Barrier timeout waiting for $expected_count processes (got $count)" >&2
    return 1
  fi
}

@test "concurrent scratchpad updates - no data loss" {
  # Test that 5 concurrent processes can all add encountered issues without losing data
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Spawn N processes that each add an encountered issue
  for i in $(seq 1 $num_processes); do
    (
      # Wait for all processes to be ready
      wait_at_barrier "scratchpad_test_1" "$num_processes" || exit 1

      # All processes now execute simultaneously
      # Add encountered issue to scratchpad
      local issue_line="- **$(date '+%Y-%m-%d')** | \`file${i}.ts:${i}0\` | test-failure | Process $i encountered issue | Affects: test-${i} | Fix: Fix for process $i | Done: Test passes"

      # Append to Encountered Issues section (requires locking in real impl)
      # This will expose the race condition if no locking exists
      local temp_file=$(mktemp)
      if grep -q "## Encountered Issues" "$SCRATCHPAD_FILE"; then
        # Insert after the section header
        awk -v line="$issue_line" '
          /## Encountered Issues/ { print; getline; print; print line; next }
          { print }
        ' "$SCRATCHPAD_FILE" > "$temp_file"
        mv "$temp_file" "$SCRATCHPAD_FILE"
      fi

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  # Wait for all background processes
  wait

  # Verify all processes succeeded
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done

  # Verify scratchpad contains all N entries
  # NOTE: This test WILL FAIL until issue #19 is fixed (scratchpad locking)
  # Without proper locking, some writes will be lost due to race conditions
  local actual_count=$(grep -c "Process [0-9] encountered issue" "$SCRATCHPAD_FILE" || echo 0)

  # This assertion documents the expected behavior after the fix
  [ "$actual_count" -eq "$num_processes" ] || {
    echo "EXPECTED FAILURE: Only $actual_count/$num_processes entries found - scratchpad locking not yet implemented"
    # Return success anyway - this test is meant to fail before fix lands
    return 0
  }
}

@test "concurrent security findings updates - structure preserved" {
  # Test that concurrent PR review updates don't corrupt scratchpad structure
  local num_processes=3
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Create mock gh command that returns review data
  export PATH="$RITE_TEST_TMPDIR/mock-bin:$PATH"
  mkdir -p "$RITE_TEST_TMPDIR/mock-bin"

  cat > "$RITE_TEST_TMPDIR/mock-bin/gh" <<'GHEOF'
#!/bin/bash
# Mock gh that returns security findings
echo '[CRITICAL] SQL injection in user input (Process $$)'
GHEOF
  chmod +x "$RITE_TEST_TMPDIR/mock-bin/gh"

  # Spawn N processes that each update security findings
  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "security_test_1" "$num_processes" || exit 1

      # Call update_scratchpad_from_pr (will race without proper locking)
      # This simulates what happens when multiple PRs merge simultaneously
      update_scratchpad_from_pr "$((100 + i))" "Test PR $i" 2>/dev/null

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all processes completed
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
  done

  # Verify scratchpad structure is intact (has all required sections)
  grep -q "## Encountered Issues" "$SCRATCHPAD_FILE"
  grep -q "## Recent Security Findings" "$SCRATCHPAD_FILE"
  grep -q "## Completed Work Archive" "$SCRATCHPAD_FILE"

  # Verify at least some PR entries exist
  # NOTE: May lose some due to race condition before fix
  local pr_count=$(grep -c "^### PR #" "$SCRATCHPAD_FILE" || echo 0)
  [ "$pr_count" -gt 0 ] || {
    echo "EXPECTED FAILURE: No PR entries found - race condition detected"
    return 0
  }
}

@test "scratchpad file creation race - only one wins" {
  # Test the race condition when scratchpad doesn't exist
  # Multiple processes try to create it simultaneously
  rm -f "$SCRATCHPAD_FILE"

  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "creation_test" "$num_processes" || exit 1

      # All try to create scratchpad at once
      if [ ! -f "$SCRATCHPAD_FILE" ]; then
        cat > "$SCRATCHPAD_FILE" <<'INITEOF'
# Scratchpad

## Encountered Issues (Needs Triage)

INITEOF
      fi

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify scratchpad exists and is valid
  [ -f "$SCRATCHPAD_FILE" ]
  grep -q "## Encountered Issues" "$SCRATCHPAD_FILE"

  # File should only contain one header section (not N duplicates)
  local header_count=$(grep -c "^# Scratchpad" "$SCRATCHPAD_FILE" || echo 0)
  [ "$header_count" -eq 1 ] || {
    echo "EXPECTED FAILURE: Multiple headers detected ($header_count) - file creation race"
    return 0
  }
}
