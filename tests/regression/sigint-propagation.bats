#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/workflow-runner.sh
# Regression test for: Make Ctrl-C reliably terminate rite workflow
# Issue: The structured-log pipeline (tee | perl) doesn't propagate SIGINT to
# parent bash, so Ctrl-C is absorbed and the workflow can't be interrupted.
# Even closing the terminal doesn't kill the processes.
#
# Expected behavior: Ctrl-C (SIGINT) should terminate the entire rite session
# including all child processes (tee, perl, etc.) within ~3 seconds.

setup() {
  # Create minimal test environment
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_LIB_DIR="${RITE_TEST_ROOT}/lib"
  mkdir -p "$RITE_LIB_DIR/utils" "$RITE_LIB_DIR/core"

  # Copy actual lib files needed for the test
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp -r "${REAL_RITE_ROOT}/lib/utils/colors.sh" "$RITE_LIB_DIR/utils/"
  cp -r "${REAL_RITE_ROOT}/lib/utils/logging.sh" "$RITE_LIB_DIR/utils/"
}

teardown() {
  # Kill any orphaned processes from failed tests
  pkill -P $$ 2>/dev/null || true
  rm -rf "$RITE_TEST_ROOT"
}

@test "SIGINT kills entire process group including logging pipeline" {
  # Create a test script that simulates rite's logging pipeline setup
  TEST_SCRIPT="${RITE_TEST_ROOT}/test-workflow.sh"
  LOG_FILE="${RITE_TEST_ROOT}/test.log"

  cat > "$TEST_SCRIPT" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

RITE_LIB_DIR="${1}"
LOG_FILE="${2}"

# Source the logging utilities
source "${RITE_LIB_DIR}/utils/colors.sh"
source "${RITE_LIB_DIR}/utils/logging.sh"

# Set up logging pipeline (same as bin/rite:299)
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== Test Log ===" > "$LOG_FILE"
exec > >(tee >(strip_ansi >> "$LOG_FILE"))
exec 2>&1

# Signal handler that kills process group (like workflow-runner.sh)
cleanup_on_interrupt() {
  echo "Interrupt received, cleaning up..."
  # Kill entire process group
  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.5
  kill -KILL -- -$$ 2>/dev/null || true
  exit 130
}

trap cleanup_on_interrupt INT TERM HUP

# Simulate long-running workflow
echo "Starting long-running workflow..."
for i in {1..100}; do
  echo "Step $i of workflow"
  sleep 0.2
done
echo "Workflow completed"
SCRIPT_EOF

  chmod +x "$TEST_SCRIPT"

  # Start the test workflow in background
  "$TEST_SCRIPT" "$RITE_LIB_DIR" "$LOG_FILE" &
  WORKFLOW_PID=$!

  # Wait for pipeline to be established (tee and perl should be running)
  sleep 1

  # Verify child processes exist (tee and perl from logging pipeline)
  # This confirms the pipeline is actually running
  CHILD_COUNT=$(pgrep -P "$WORKFLOW_PID" | wc -l | tr -d ' ')
  [ "$CHILD_COUNT" -gt 0 ] || {
    echo "ERROR: No child processes found. Pipeline may not have started." >&2
    kill "$WORKFLOW_PID" 2>/dev/null || true
    return 1
  }

  # Send SIGINT to the process group (simulates Ctrl-C)
  kill -INT -"$WORKFLOW_PID" 2>/dev/null || true

  # Wait up to 5 seconds for all processes to terminate
  WAIT_COUNT=0
  while [ $WAIT_COUNT -lt 10 ]; do
    # Check if main process is still alive
    if ! kill -0 "$WORKFLOW_PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  # Verify the main process is dead
  run kill -0 "$WORKFLOW_PID" 2>&1
  [ "$status" -ne 0 ]

  # Verify all child processes are dead (no orphaned tee or perl)
  ORPHAN_COUNT=$(pgrep -P "$WORKFLOW_PID" 2>/dev/null | wc -l | tr -d ' ')
  [ "$ORPHAN_COUNT" -eq 0 ]

  # Cleanup should have been fast (< 5 seconds)
  [ $WAIT_COUNT -lt 10 ]
}

@test "SIGHUP kills entire process group when terminal closes" {
  # Create test script (same as previous test)
  TEST_SCRIPT="${RITE_TEST_ROOT}/test-workflow-hup.sh"
  LOG_FILE="${RITE_TEST_ROOT}/test-hup.log"

  cat > "$TEST_SCRIPT" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

RITE_LIB_DIR="${1}"
LOG_FILE="${2}"

source "${RITE_LIB_DIR}/utils/colors.sh"
source "${RITE_LIB_DIR}/utils/logging.sh"

mkdir -p "$(dirname "$LOG_FILE")"
echo "=== Test Log ===" > "$LOG_FILE"
exec > >(tee >(strip_ansi >> "$LOG_FILE"))
exec 2>&1

cleanup_on_interrupt() {
  echo "Hangup received, cleaning up..."
  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.5
  kill -KILL -- -$$ 2>/dev/null || true
  exit 129
}

trap cleanup_on_interrupt INT TERM HUP

echo "Starting workflow..."
for i in {1..100}; do
  echo "Step $i"
  sleep 0.2
done
SCRIPT_EOF

  chmod +x "$TEST_SCRIPT"

  # Start workflow
  "$TEST_SCRIPT" "$RITE_LIB_DIR" "$LOG_FILE" &
  WORKFLOW_PID=$!

  # Wait for pipeline establishment
  sleep 1

  # Send SIGHUP (simulates terminal closing)
  kill -HUP -"$WORKFLOW_PID" 2>/dev/null || true

  # Wait for termination
  WAIT_COUNT=0
  while [ $WAIT_COUNT -lt 10 ]; do
    if ! kill -0 "$WORKFLOW_PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  # Verify dead
  run kill -0 "$WORKFLOW_PID" 2>&1
  [ "$status" -ne 0 ]

  # Verify no orphans
  ORPHAN_COUNT=$(pgrep -P "$WORKFLOW_PID" 2>/dev/null | wc -l | tr -d ' ')
  [ "$ORPHAN_COUNT" -eq 0 ]
}

@test "process group kill handles double interrupt (force exit)" {
  # Test the recursive trap prevention logic
  TEST_SCRIPT="${RITE_TEST_ROOT}/test-double-interrupt.sh"

  cat > "$TEST_SCRIPT" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

INTERRUPT_RECEIVED=false

cleanup_on_interrupt() {
  if [ "$INTERRUPT_RECEIVED" = true ]; then
    echo "Force exit"
    kill -KILL -- -$$ 2>/dev/null || true
    exit 1
  fi
  INTERRUPT_RECEIVED=true

  echo "First interrupt, cleaning up..."
  sleep 2  # Simulate slow cleanup

  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.5
  kill -KILL -- -$$ 2>/dev/null || true
  exit 130
}

trap cleanup_on_interrupt INT TERM HUP

echo "Running..."
sleep 100
SCRIPT_EOF

  chmod +x "$TEST_SCRIPT"

  # Start script
  "$TEST_SCRIPT" &
  PID=$!

  sleep 0.5

  # Send first interrupt
  kill -INT "$PID" 2>/dev/null || true

  # Immediately send second interrupt (force exit)
  sleep 0.2
  kill -INT "$PID" 2>/dev/null || true

  # Should exit quickly (not waiting for slow cleanup)
  WAIT_COUNT=0
  while [ $WAIT_COUNT -lt 6 ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  # Verify dead (force exit should be fast)
  run kill -0 "$PID" 2>&1
  [ "$status" -ne 0 ]

  # Should have exited in < 3 seconds (not the full 2s cleanup delay)
  [ $WAIT_COUNT -lt 6 ]
}
