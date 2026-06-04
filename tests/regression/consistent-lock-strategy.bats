#!/usr/bin/env bats
# Regression test for: Use consistent lock paths across all processes
# Issue #148: Lock strategy (flock vs mkdir) was re-detected independently at
# acquire and release time via `command -v flock`.  In mixed-capability
# environments (differing PATH, Homebrew util-linux only on some hosts, or an
# NFS mount shared between flock-capable and non-capable machines) this could
# cause acquire to create a plain file while release expected a directory (or
# vice versa), leaving a stale lock artifact that permanently blocks subsequent
# acquires.
#
# Fix: persist the chosen strategy in _SCRATCHPAD_LOCK_STRATEGY /
# _SESSION_LOCK_STRATEGY at acquire time and read it in release.
#
# Also verifies:
#   - Symmetric cleanup: flock path removes a leftover mkdir-style directory
#   - Symmetric cleanup: mkdir path removes a leftover flock-style plain file
#   - issue-lock.sh PID writes are now atomic (mktemp + mv)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export SCRATCHPAD_FILE="$RITE_TEST_TMPDIR/$RITE_DATA_DIR/scratch.md"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/$RITE_DATA_DIR/locks"

  mkdir -p "$RITE_TEST_TMPDIR/$RITE_DATA_DIR"
  mkdir -p "$RITE_LOCK_DIR"

  touch "$SCRATCHPAD_FILE"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# scratchpad-lock.sh: strategy is persisted and release uses correct path type
# ---------------------------------------------------------------------------

@test "scratchpad-lock: _SCRATCHPAD_LOCK_STRATEGY is set to 'mkdir' on mkdir path" {
  # Force the mkdir path by hiding flock from PATH
  run bash -c "
    export PATH=\"\$(echo \"\$PATH\" | tr ':' '\n' | grep -v 'util-linux' | tr '\n' ':' | sed 's/:$//')\"
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

    # Verify flock is not available in modified PATH (skip test on systems with system flock)
    if command -v flock >/dev/null 2>&1; then
      echo 'SKIP: flock is available in system PATH; cannot force mkdir path'
      exit 0
    fi

    export SCRATCHPAD_FILE='${SCRATCHPAD_FILE}'
    acquire_scratchpad_lock

    if [ \"\${_SCRATCHPAD_LOCK_STRATEGY:-}\" = 'mkdir' ]; then
      echo 'PASS: strategy is mkdir'
    else
      echo \"FAIL: expected mkdir, got '\${_SCRATCHPAD_LOCK_STRATEGY:-unset}'\"
      exit 1
    fi

    release_scratchpad_lock
  "
  [ "$status" -eq 0 ]
  # Either we got a PASS or flock was unavoidable — both are acceptable
  [[ "$output" == *"PASS: strategy is mkdir"* ]] || [[ "$output" == *"SKIP:"* ]]
}

@test "scratchpad-lock: mkdir path release removes lock directory" {
  # Acquire via the mkdir path (hide flock) and verify release cleans up the dir
  run bash -c "
    export PATH=\"\$(echo \"\$PATH\" | tr ':' '\n' | grep -v 'util-linux' | tr '\n' ':' | sed 's/:$//')\"
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

    if command -v flock >/dev/null 2>&1; then
      echo 'SKIP: flock is available in system PATH; cannot force mkdir path'
      exit 0
    fi

    export SCRATCHPAD_FILE='${SCRATCHPAD_FILE}'
    _lockfile=\"\${SCRATCHPAD_FILE}.lock\"

    acquire_scratchpad_lock

    # Lock directory must exist after acquire
    [ -d \"\$_lockfile\" ] || { echo 'FAIL: lock dir not created'; exit 1; }

    release_scratchpad_lock

    # Lock directory must be gone after release
    if [ -e \"\$_lockfile\" ]; then
      echo 'FAIL: lock dir still exists after release'
      exit 1
    fi
    echo 'PASS: lock dir removed on release'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: lock dir removed on release"* ]] || [[ "$output" == *"SKIP:"* ]]
}

@test "scratchpad-lock: flock path cleans up leftover mkdir-style lock directory" {
  # Simulate the mixed-environment scenario: a previous run used mkdir and left
  # a stale lock directory.  A new run on a flock-capable host must remove it
  # before acquiring the flock.
  run bash -c "
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

    if ! command -v flock >/dev/null 2>&1; then
      echo 'SKIP: flock not available on this system'
      exit 0
    fi

    export SCRATCHPAD_FILE='${SCRATCHPAD_FILE}'
    _lockfile=\"\${SCRATCHPAD_FILE}.lock\"

    # Simulate stale mkdir-style lock from a dead process (no live PID).
    # Use a completed subshell rather than a hardcoded value like 99999999 —
    # on Linux systems with pid_max > 99999 (containers, custom kernel configs)
    # a hardcoded large PID may actually be alive, causing flaky test failures.
    mkdir -p \"\$_lockfile\"
    ( true ) & _dead_pid=\$!; wait \"\$_dead_pid\" 2>/dev/null || true
    echo \"\$_dead_pid\" > \"\$_lockfile/pid\"

    # Acquire must succeed — it should remove the stale dir first
    if acquire_scratchpad_lock; then
      echo 'PASS: acquired lock despite leftover mkdir dir'
      release_scratchpad_lock
    else
      echo 'FAIL: could not acquire lock'
      exit 1
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: acquired lock despite leftover mkdir dir"* ]] || [[ "$output" == *"SKIP:"* ]]
}

@test "scratchpad-lock: mkdir path cleans up leftover flock-style plain file" {
  # Simulate the reverse: a previous flock run left a plain file.  A new run
  # on a system without flock (mkdir path) must remove it before mkdir-ing.
  run bash -c "
    export PATH=\"\$(echo \"\$PATH\" | tr ':' '\n' | grep -v 'util-linux' | tr '\n' ':' | sed 's/:$//')\"
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

    if command -v flock >/dev/null 2>&1; then
      echo 'SKIP: flock is available in system PATH; cannot force mkdir path'
      exit 0
    fi

    export SCRATCHPAD_FILE='${SCRATCHPAD_FILE}'
    _lockfile=\"\${SCRATCHPAD_FILE}.lock\"

    # Simulate stale flock-style plain file
    touch \"\$_lockfile\"

    # Acquire must succeed — it should remove the stale file first
    if acquire_scratchpad_lock; then
      echo 'PASS: acquired lock despite leftover plain file'
      release_scratchpad_lock
    else
      echo 'FAIL: could not acquire lock'
      exit 1
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: acquired lock despite leftover plain file"* ]] || [[ "$output" == *"SKIP:"* ]]
}

# ---------------------------------------------------------------------------
# issue-lock.sh: PID file is written atomically via mktemp + mv
# ---------------------------------------------------------------------------

@test "issue-lock: PID file is present immediately after acquire (atomic write)" {
  # Verify the PID file exists right after acquire returns — no window where
  # lock dir exists but has no PID (the old non-atomic echo > file race).
  run bash -c "
    export RITE_PROJECT_ROOT='${RITE_TEST_TMPDIR}'
    export RITE_DATA_DIR='.rite'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${RITE_LIB_DIR}/utils/issue-lock.sh'

    acquire_issue_lock 555

    _lock_dir=\"\${RITE_LOCK_DIR}/issue-555.lock\"

    # Lock dir must exist
    [ -d \"\$_lock_dir\" ] || { echo 'FAIL: lock dir not created'; exit 1; }

    # PID file must exist immediately — no grace period, no polling needed
    [ -f \"\$_lock_dir/pid\" ] || { echo 'FAIL: PID file missing immediately after acquire'; exit 1; }

    # PID file must contain our PID
    _written_pid=\$(cat \"\$_lock_dir/pid\")
    [ \"\$_written_pid\" = \"\$\$\" ] || { echo \"FAIL: PID mismatch: expected \$\$ got \$_written_pid\"; exit 1; }

    release_issue_lock 555
    echo 'PASS: PID file present immediately after acquire'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: PID file present immediately after acquire"* ]]
}

@test "issue-lock: PID file is present immediately after followup lock acquire" {
  run bash -c "
    export RITE_PROJECT_ROOT='${RITE_TEST_TMPDIR}'
    export RITE_DATA_DIR='.rite'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${RITE_LIB_DIR}/utils/issue-lock.sh'

    acquire_pr_followup_lock 101 42

    _lock_dir=\"\${RITE_LOCK_DIR}/pr-101-src-42-followup.lock\"

    [ -d \"\$_lock_dir\" ] || { echo 'FAIL: followup lock dir not created'; exit 1; }
    [ -f \"\$_lock_dir/pid\" ] || { echo 'FAIL: PID file missing after followup acquire'; exit 1; }

    _written_pid=\$(cat \"\$_lock_dir/pid\")
    [ \"\$_written_pid\" = \"\$\$\" ] || { echo \"FAIL: PID mismatch: expected \$\$ got \$_written_pid\"; exit 1; }

    release_pr_followup_lock 101 42
    echo 'PASS: followup PID file present immediately after acquire'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: followup PID file present immediately after acquire"* ]]
}

# ---------------------------------------------------------------------------
# session-tracker.sh: strategy is persisted across acquire/release
# ---------------------------------------------------------------------------

@test "session-lock: _SESSION_LOCK_STRATEGY is cleared after release" {
  # After release, _SESSION_LOCK_STRATEGY must be empty so a subsequent acquire
  # picks the fresh strategy for the current environment.
  run bash -c "
    export SESSION_STATE_FILE='${RITE_TEST_TMPDIR}/test-session.json'
    source '${RITE_LIB_DIR}/utils/session-tracker.sh'

    _acquire_session_lock

    # Strategy must be set after acquire
    [ -n \"\${_SESSION_LOCK_STRATEGY:-}\" ] || { echo 'FAIL: strategy unset after acquire'; exit 1; }

    _release_session_lock

    # Strategy must be cleared after release
    if [ -n \"\${_SESSION_LOCK_STRATEGY:-}\" ]; then
      echo \"FAIL: strategy still set after release: '\${_SESSION_LOCK_STRATEGY}'\"
      exit 1
    fi
    echo 'PASS: strategy cleared after release'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: strategy cleared after release"* ]]
}

@test "session-lock: _SESSION_LOCK_HELD is false after release" {
  run bash -c "
    export SESSION_STATE_FILE='${RITE_TEST_TMPDIR}/test-session2.json'
    source '${RITE_LIB_DIR}/utils/session-tracker.sh'

    _acquire_session_lock
    [ \"\$_SESSION_LOCK_HELD\" = 'true' ] || { echo 'FAIL: HELD not true after acquire'; exit 1; }

    _release_session_lock
    [ \"\$_SESSION_LOCK_HELD\" = 'false' ] || { echo 'FAIL: HELD still true after release'; exit 1; }

    echo 'PASS: HELD state correct'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: HELD state correct"* ]]
}
