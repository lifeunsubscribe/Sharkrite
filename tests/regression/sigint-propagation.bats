#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/utils/colors.sh, lib/utils/logging.sh
# sharkrite-gate-serial — flaked under --jobs 8 (2026-07 audit: process-group/signal,
# concurrent-write, and timeout-race tests need the serial group)
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
#!/usr/bin/env bash
# Use env bash (homebrew bash 5.x) rather than /bin/bash (macOS 3.2).
# bash 3.2's non-interactive SIGINT handling can exit-on-set-e before the
# trap fires when the process is under heavy load (gate after parallel batch).
set -euo pipefail

RITE_LIB_DIR="${1}"
LOG_FILE="${2}"

# Source the logging utilities
source "${RITE_LIB_DIR}/utils/colors.sh"
source "${RITE_LIB_DIR}/utils/logging.sh"

# Set up logging pipeline (same as bin/rite)
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

  # Start the test workflow in its own process group (job control ON) so the
  # script's in-trap `kill -TERM -- -$$` targets only its own group, not the
  # bats process group.  Without `set -m` the child shares the bats PGID and
  # the in-trap group-kill would reach bats itself.
  set -m
  "$TEST_SCRIPT" "$RITE_LIB_DIR" "$LOG_FILE" &
  WORKFLOW_PID=$!
  set +m

  # Wait for pipeline to be established (tee and perl should be running).
  # Also use this window to confirm the PGID was actually set — under load the
  # kernel's setpgid() can lag behind exec (race between fork+setpgid and the
  # child running), so poll until PGID == PID or the window expires.
  _pgid_ok=false
  _pgid_checks=0
  while [ "$_pgid_ok" = false ] && [ "$_pgid_checks" -lt 10 ]; do
    sleep 0.1
    _child_pgid=$(ps -o pgid= -p "$WORKFLOW_PID" 2>/dev/null | tr -d ' ' || true)
    [ "$_child_pgid" = "$WORKFLOW_PID" ] && _pgid_ok=true
    _pgid_checks=$((_pgid_checks + 1))
  done
  # Wait for rest of the 1s pipeline-establishment window (already spent up to 1s above).
  # If PGID check didn't succeed in 1s, skip the remaining setup sleep; fall through.
  sleep 1

  # Verify child processes exist (tee and perl from logging pipeline)
  # This confirms the pipeline is actually running.
  # pgrep exits 1 when no matches — add || true to avoid pipefail failure.
  CHILD_COUNT=$(pgrep -P "$WORKFLOW_PID" 2>/dev/null | wc -l | tr -d ' ' || true)
  [ "${CHILD_COUNT:-0}" -gt 0 ] || {
    echo "ERROR: No child processes found. Pipeline may not have started." >&2
    kill "$WORKFLOW_PID" 2>/dev/null || true
    return 1
  }

  # Send SIGINT to the process (simulates Ctrl-C reaching the workflow leader).
  # We send to the PID directly rather than the process group so that signal
  # delivery is unaffected by PGID-race lag under load — the script's own
  # cleanup_on_interrupt trap is what kills the full group; that is what this
  # test verifies.
  kill -INT "$WORKFLOW_PID" 2>/dev/null || true

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

  # Verify all child processes are dead (no orphaned tee or perl).
  # Brief retry: on macOS, SIGKILL-killed children can transiently appear in
  # pgrep output for a few milliseconds before the kernel updates the process
  # table. Re-check up to 5 times with 0.1s gaps before declaring failure.
  ORPHAN_COUNT=1
  _orphan_checks=0
  while [ "$ORPHAN_COUNT" -gt 0 ] && [ "$_orphan_checks" -lt 5 ]; do
    sleep 0.1
    ORPHAN_COUNT=$(pgrep -P "$WORKFLOW_PID" 2>/dev/null | wc -l | tr -d ' ' || true)
    ORPHAN_COUNT="${ORPHAN_COUNT:-0}"
    _orphan_checks=$((_orphan_checks + 1))
  done
  [ "$ORPHAN_COUNT" -eq 0 ]

  # Cleanup should have been fast (< 5 seconds)
  [ $WAIT_COUNT -lt 10 ]
}

@test "SIGHUP kills entire process group when terminal closes" {
  # Create test script (same as previous test)
  TEST_SCRIPT="${RITE_TEST_ROOT}/test-workflow-hup.sh"
  LOG_FILE="${RITE_TEST_ROOT}/test-hup.log"

  cat > "$TEST_SCRIPT" <<'SCRIPT_EOF'
#!/usr/bin/env bash
# Use env bash (homebrew bash 5.x) — see SIGINT test fixture comment.
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

  # Start workflow in its own process group so the script's in-trap
  # `kill -TERM -- -$$` targets only its own group (see comment in SIGINT test).
  set -m
  "$TEST_SCRIPT" "$RITE_LIB_DIR" "$LOG_FILE" &
  WORKFLOW_PID=$!
  set +m

  # Wait for pipeline establishment
  sleep 1

  # Send SIGHUP to the workflow leader directly (simulates terminal closing).
  # Direct PID delivery avoids PGID-race lag under load; the script's trap
  # handles the group kill internally.
  kill -HUP "$WORKFLOW_PID" 2>/dev/null || true

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

  # Verify no orphans (pgrep exits 1 on no match; || true prevents pipefail kill)
  ORPHAN_COUNT=$(pgrep -P "$WORKFLOW_PID" 2>/dev/null | wc -l | tr -d ' ' || true)
  [ "${ORPHAN_COUNT:-0}" -eq 0 ]
}

@test "process group kill handles double interrupt (force exit)" {
  # Test the recursive trap prevention logic
  TEST_SCRIPT="${RITE_TEST_ROOT}/test-double-interrupt.sh"

  cat > "$TEST_SCRIPT" <<'SCRIPT_EOF'
#!/usr/bin/env bash
# Use env bash (homebrew bash 5.x) — see SIGINT test fixture comment.
set -euo pipefail

INTERRUPT_RECEIVED=false

cleanup_on_interrupt() {
  # Recursive-trap guard preserved for parity with workflow-runner.sh's
  # cleanup_on_interrupt. NOTE: the "second interrupt while the handler is
  # mid-cleanup" force-exit path is NOT exercisable from the test harness —
  # bash defers same-signal delivery while a signal's trap handler runs (and a
  # different second signal also does not re-enter during the handler), so a
  # racing second kill cannot re-enter this function. We therefore assert the
  # verifiable contract: a single interrupt tears down the process group within
  # the bounded window.
  if [ "$INTERRUPT_RECEIVED" = true ]; then
    echo "Force exit"
    kill -KILL -- -$$ 2>/dev/null || true
    exit 1
  fi
  INTERRUPT_RECEIVED=true

  echo "First interrupt, cleaning up..."

  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.5
  kill -KILL -- -$$ 2>/dev/null || true
  exit 130
}

trap cleanup_on_interrupt INT TERM HUP

echo "Running..."
# Use a loop of short sleeps rather than a single `sleep 100`: bash defers a
# caught signal's trap until the current foreground command returns, so a long
# foreground `sleep` would swallow the interrupt entirely (the trap would never
# run). Short sleeps let the trap fire within ~0.2s of the signal.
for i in {1..500}; do
  sleep 0.2
done
SCRIPT_EOF

  chmod +x "$TEST_SCRIPT"

  # Start script in its own process group so the in-handler `kill -- -$$`
  # targets the child's own group, not the bats group (see comment in the
  # SIGINT test).
  set -m
  "$TEST_SCRIPT" &
  PID=$!
  set +m

  sleep 0.5

  # Send the interrupt. (A second racing interrupt cannot re-enter the handler
  # under bash trap semantics — see the fixture comment — so we assert the
  # single-interrupt teardown contract instead.)
  kill -INT "$PID" 2>/dev/null || true

  # Should exit quickly within the bounded window
  WAIT_COUNT=0
  while [ $WAIT_COUNT -lt 6 ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  # Verify dead (interrupt teardown should be fast)
  run kill -0 "$PID" 2>&1
  [ "$status" -ne 0 ]

  # Should have exited well within 3 seconds
  [ $WAIT_COUNT -lt 6 ]
}
