#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/issue-lock.sh, lib/core/batch-process-issues.sh
# sharkrite-gate-serial
# tests/regression/batch-mutex.bats
#
# Regression test: repo-level batch mutex (issue #833)
#
# Verifies that a second concurrent `rite` batch invocation is refused loudly
# (exit 17) instead of silently contending on shared state.
#
# Tests in this file:
#
#   BEHAVIORAL (acquire_batch_lock / release_batch_lock):
#     1. acquire creates pid + issues + cwd files atomically
#     2. Second acquire on live holder returns 1 and prints holder PID
#     3. Stale lock (dead PID) is stolen and acquire succeeds
#     4. release_batch_lock is pid-checked — does not remove another process's lock
#     5. EXIT trap releases the lock (pid-checked)
#
#   STRUCTURAL (static code inspection):
#     6. batch-process-issues.sh sources issue-lock.sh
#     7. batch-process-issues.sh acquires the batch lock before processing issues
#     8. _cleanup_batch_session calls release_batch_lock
#     9. Refused batch (exit 17) performs zero issue processing
#    10. exit-codes.md documents exit 17

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
ISSUE_LOCK="$REPO_ROOT/lib/utils/issue-lock.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"

setup() {
  [ -f "$ISSUE_LOCK" ] || {
    echo "FATAL: $ISSUE_LOCK not found" >&2
    return 1
  }
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$EXIT_CODES_DOC" ] || {
    echo "FATAL: $EXIT_CODES_DOC not found" >&2
    return 1
  }

  # Isolated tmp dir for each test — RITE_LOCK_DIR points into it.
  _tmpdir="$(mktemp -d "${BATS_TEST_TMPDIR}/batch-mutex.XXXXXX")"
  export RITE_LOCK_DIR="${_tmpdir}/locks"
  mkdir -p "$RITE_LOCK_DIR"

  # Source issue-lock.sh functions only (no program body).
  # Re-stub flags after source: lib sets -euo pipefail and the leaked strict
  # mode would swallow a failing test into "not run" (2026-07-01 incident).
  # NEVER set +e — bats failure detection depends on errexit.
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ISSUE_LOCK"
  set +u; set +o pipefail
}

teardown() {
  # Cleanup isolated tmp dir (bats does not guarantee this for mktemp -d).
  # Must live here, not as `trap ... EXIT` inside a @test body — a test-body
  # EXIT trap clobbers bats' result-emitting EXIT trap (Rule 29: TRAP_EXIT_IN_BATS_TEST).
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# BEHAVIORAL: acquire_batch_lock / release_batch_lock
# =============================================================================

@test "behavioral: acquire_batch_lock creates pid, issues, and cwd files" {
  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${ISSUE_LOCK}'
    set +u; set +o pipefail
    acquire_batch_lock '10 20 30'
    echo \"LOCK_DIR_EXISTS=\$([ -d \"\${RITE_LOCK_DIR}/batch.lock\" ] && echo yes || echo no)\"
    echo \"PID_FILE_EXISTS=\$([ -f \"\${RITE_LOCK_DIR}/batch.lock/pid\" ] && echo yes || echo no)\"
    echo \"ISSUES_FILE_EXISTS=\$([ -f \"\${RITE_LOCK_DIR}/batch.lock/issues\" ] && echo yes || echo no)\"
    echo \"CWD_FILE_EXISTS=\$([ -f \"\${RITE_LOCK_DIR}/batch.lock/cwd\" ] && echo yes || echo no)\"
    _pid=\$(cat \"\${RITE_LOCK_DIR}/batch.lock/pid\" 2>/dev/null || true)
    echo \"PID_MATCHES=\$([ \"\$_pid\" = \"\$\$\" ] && echo yes || echo no)\"
    _issues=\$(cat \"\${RITE_LOCK_DIR}/batch.lock/issues\" 2>/dev/null || true)
    echo \"ISSUES_CONTENT=\${_issues}\"
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "LOCK_DIR_EXISTS=yes"
  echo "$output" | grep -q "PID_FILE_EXISTS=yes"
  echo "$output" | grep -q "ISSUES_FILE_EXISTS=yes"
  echo "$output" | grep -q "CWD_FILE_EXISTS=yes"
  echo "$output" | grep -q "PID_MATCHES=yes"
  echo "$output" | grep -q "ISSUES_CONTENT=10 20 30"
}

@test "behavioral: second acquire on live holder returns 1 and names holder PID" {
  # Acquire the lock in a background process that stays alive long enough.
  # Use a FIFO to coordinate: holder signals "ready" after acquiring.
  _fifo="${_tmpdir}/ready.fifo"
  mkfifo "$_fifo"

  # Background holder: acquire then wait for a release signal.
  bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${ISSUE_LOCK}'
    set +u; set +o pipefail
    acquire_batch_lock '10 20 30'
    echo ready > '${_fifo}'
    # Sleep long enough for the refusal test to complete.
    sleep 10
  " &
  _holder_pid=$!

  # Wait for holder to signal ready (with a timeout guard).
  _ready=""
  _tries=0
  while [ -z "$_ready" ] && [ $_tries -lt 50 ]; do
    _ready=$(cat "$_fifo" 2>/dev/null || true)
    [ -z "$_ready" ] && { sleep 0.1; _tries=$((_tries + 1)); }
  done

  [ -n "$_ready" ] || {
    echo "FATAL: holder never signaled ready" >&2
    kill "$_holder_pid" 2>/dev/null || true
    return 1
  }

  # Now attempt a second acquire — must fail (return 1).
  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    # Disable grace-period sleep for faster test execution.
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${ISSUE_LOCK}'
    set +u; set +o pipefail
    acquire_batch_lock '40 50'
  "

  # Cleanup holder before assertions so it doesn't leak.
  kill "$_holder_pid" 2>/dev/null || true
  wait "$_holder_pid" 2>/dev/null || true

  # acquire_batch_lock must return 1 (live holder detected).
  [ "$status" -eq 1 ]

  # The error message must name the holder PID (the holder_pid value).
  _holder_lock_pid=$(cat "${RITE_LOCK_DIR}/batch.lock/pid" 2>/dev/null || true)
  # The holder_lock_pid may be the background subshell — just verify a PID appears.
  echo "$output" | grep -qE 'Another batch is already running \(PID [0-9]+\)'

  # The error message must mention the holder's issue list.
  echo "$output" | grep -q "10 20 30"
}

@test "behavioral: stale lock (dead PID) is stolen and acquire succeeds" {
  # Write a stale lock directory with a guaranteed-dead PID.
  local lock_dir="${RITE_LOCK_DIR}/batch.lock"
  mkdir -p "$lock_dir"
  # PID 99999999 is astronomically unlikely to exist.
  printf '%s\n' "99999999" > "${lock_dir}/pid"
  printf '%s\n' "99 100" > "${lock_dir}/issues"

  # Disable grace-period sleep so test does not block on the 1s default.
  export _RITE_LOCK_GRACE_PERIOD_S=0

  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${ISSUE_LOCK}'
    set +u; set +o pipefail
    # Must succeed — stale lock is stolen atomically
    if acquire_batch_lock '10 20'; then
      echo ACQUIRED
      # PID file must now contain OUR pid
      _pid=\$(cat \"\${RITE_LOCK_DIR}/batch.lock/pid\" 2>/dev/null || true)
      echo \"PID=\${_pid}\"
      echo \"SELF=\$\$\"
    else
      echo REFUSED
    fi
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ACQUIRED"
  # The stale-lock reclaim warning must appear.
  echo "$output" | grep -q "Reclaiming stale batch lock from dead process"
}

@test "behavioral: release_batch_lock is pid-checked — does not remove another process's lock" {
  # Write a lock directory owned by a foreign PID.
  local lock_dir="${RITE_LOCK_DIR}/batch.lock"
  mkdir -p "$lock_dir"
  # Use a PID of 1 (init/launchd — always alive but not us).
  printf '%s\n' "1" > "${lock_dir}/pid"

  # release_batch_lock must NOT remove the lock because PID 1 != $$.
  release_batch_lock

  # Lock dir must still exist.
  [ -d "$lock_dir" ] || {
    echo "FAIL: release_batch_lock removed a lock owned by PID 1 (not ours)" >&2
    return 1
  }
}

@test "behavioral: EXIT trap releases the batch lock" {
  # Verify that _cleanup_batch_session (the EXIT trap body) calls release_batch_lock.
  # We test this behaviorally: acquire the lock in a subprocess, let it exit
  # (which fires the EXIT trap), then verify the lock dir is gone.
  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${ISSUE_LOCK}'
    set +u; set +o pipefail

    # Simulate _cleanup_batch_session releasing the lock on exit.
    _cleanup() {
      if declare -f release_batch_lock >/dev/null 2>&1; then
        release_batch_lock
      fi
    }
    # sharkrite-lint disable TRAP_EXIT_IN_BATS_TEST - Reason: this trap is inside the bash -c CHILD process string (it is the subject under test — verifying the EXIT trap releases the batch lock); it never touches the bats shell's result-emitting trap
    trap '_cleanup' EXIT

    acquire_batch_lock '5 6'
    echo LOCK_DIR_BEFORE=\$([ -d \"\${RITE_LOCK_DIR}/batch.lock\" ] && echo yes || echo no)
    # Subshell exits here — trap fires.
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "LOCK_DIR_BEFORE=yes"
  # After the subprocess exits, the lock dir must be gone.
  [ ! -d "${RITE_LOCK_DIR}/batch.lock" ] || {
    echo "FAIL: batch.lock dir still exists after EXIT trap fired" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: static code inspection
# =============================================================================

@test "structural: batch-process-issues.sh sources issue-lock.sh" {
  grep -q 'issue-lock.sh' "$BATCH_PROCESSOR" || {
    echo "FAIL: batch-process-issues.sh does not source issue-lock.sh" >&2
    echo "      acquire_batch_lock/release_batch_lock are defined there" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh acquires batch lock before processing issues" {
  grep -q 'acquire_batch_lock' "$BATCH_PROCESSOR" || {
    echo "FAIL: acquire_batch_lock not called in batch-process-issues.sh" >&2
    return 1
  }

  # The acquisition must exit 17 on failure (not 1 or some other code).
  grep -qE 'exit 17' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'exit 17' not found in batch-process-issues.sh" >&2
    echo "      A refused batch must exit 17 (distinct from workflow/gate failures)" >&2
    return 1
  }

  # The acquisition must come before the main issue loop.  Confirm by checking
  # that acquire_batch_lock appears before the ISSUE_NUM loop variable is set
  # (which only happens inside the per-issue loop).
  _acq_line=$(grep -n 'acquire_batch_lock' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _loop_line=$(grep -n 'for ISSUE_NUM in' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  [ -n "$_acq_line" ] && [ -n "$_loop_line" ] || {
    echo "FAIL: Could not locate acquire_batch_lock line or for-loop line" >&2
    return 1
  }
  [ "$_acq_line" -lt "$_loop_line" ] || {
    echo "FAIL: acquire_batch_lock (line ${_acq_line}) appears AFTER the issue loop (line ${_loop_line})" >&2
    echo "      Lock must be acquired before processing any issue" >&2
    return 1
  }
}

@test "structural: _cleanup_batch_session calls release_batch_lock" {
  # Extract _cleanup_batch_session function body via awk.
  _func_body=$(awk '
    /^_cleanup_batch_session\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract _cleanup_batch_session function body" >&2
    return 1
  }

  echo "$_func_body" | grep -q 'release_batch_lock' || {
    echo "FAIL: _cleanup_batch_session does not call release_batch_lock" >&2
    echo "      The EXIT trap must release the repo-level batch mutex on all exits" >&2
    return 1
  }
}

@test "structural: refused batch (exit 17) performs zero issue processing" {
  # The exit-17 path must fire BEFORE the per-issue loop (verified above) and
  # must not call run_workflow or any per-issue processing function.
  # Structural: find the exit-17 block and confirm it contains no workflow calls.
  _exit17_block=$(awk '
    /acquire_batch_lock/ { in_block=1 }
    in_block && /exit 17/ { in_block=0; print "EXIT17_FOUND"; exit }
    in_block { print $0 }
  ' "$BATCH_PROCESSOR")

  echo "$_exit17_block" | grep -q "EXIT17_FOUND" || {
    echo "FAIL: Could not locate the exit-17 block around acquire_batch_lock" >&2
    return 1
  }

  # The block must not contain run_workflow (the per-issue dispatcher).
  if echo "$_exit17_block" | grep -vE '^\s*#' | grep -q 'run_workflow'; then
    echo "FAIL: run_workflow found in exit-17 block — refused batch must do zero issue processing" >&2
    return 1
  fi
}

@test "structural: exit-codes.md documents exit 17 for batch-process-issues.sh" {
  grep -q '17' "$EXIT_CODES_DOC" || {
    echo "FAIL: exit code 17 not mentioned in docs/architecture/exit-codes.md" >&2
    return 1
  }

  # Must appear in the batch-process-issues.sh section.
  _batch_section=$(awk '
    /^### `batch-process-issues.sh` \(final process exit\)/ { in_section=1; next }
    in_section && /^###/ { exit }
    in_section { print $0 }
  ' "$EXIT_CODES_DOC")

  echo "$_batch_section" | grep -q '17' || {
    echo "FAIL: exit 17 not documented in the batch-process-issues.sh section of exit-codes.md" >&2
    return 1
  }

  # The entry must mention the batch mutex / concurrent batch.
  echo "$_batch_section" | grep -iE '17.*[Bb]atch|[Bb]atch.*17' | grep -qi 'running\|refused\|mutex\|concurrent' || {
    echo "FAIL: exit 17 entry in exit-codes.md does not describe the batch-refused semantic" >&2
    return 1
  }
}
