#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/issue-lock.sh, lib/utils/scratchpad-lock.sh, lib/utils/session-tracker.sh, lib/utils/lock.sh
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
  # Force the portable path with the strategy override. Do NOT skip when flock
  # is installed: a test that only executes on machines without flock runs
  # nowhere but the macOS CI job, so the gate cannot see it break (#1697).
  run bash -c "
    export RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

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
  [[ "$output" == *"PASS: strategy is mkdir"* ]]
}

@test "scratchpad-lock: portable path lock is a PID symlink, removed on release" {
  # The portable lock is a symlink whose target is the holder's PID (#1651):
  # atomic to create, and never observable without an owner.
  run bash -c "
    export RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

    export SCRATCHPAD_FILE='${SCRATCHPAD_FILE}'
    _lockfile=\"\${SCRATCHPAD_FILE}.lock\"

    acquire_scratchpad_lock

    # Lock must exist after acquire, as a symlink naming this shell's PID
    [ -L \"\$_lockfile\" ] || { echo 'FAIL: lock is not a symlink after acquire'; exit 1; }
    _owner=\$(readlink \"\$_lockfile\")
    [ \"\$_owner\" = \"\$\$\" ] || { echo \"FAIL: lock owner '\$_owner' is not this shell (\$\$)\"; exit 1; }

    release_scratchpad_lock

    # Lock must be gone after release (-L catches a dangling symlink that -e misses)
    if [ -e \"\$_lockfile\" ] || [ -L \"\$_lockfile\" ]; then
      echo 'FAIL: lock still exists after release'
      exit 1
    fi
    echo 'PASS: lock removed on release'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: lock removed on release"* ]]
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
    # get_dead_pid() from setup.bash is not available in this bash -c subshell
    # context (helpers are not sourced here), so we inline the equivalent logic
    # directly. If get_dead_pid() changes, update this inline copy too.
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
  # on the portable path must remove it before taking the lock.
  run bash -c "
    export RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir
    source '${RITE_LIB_DIR}/utils/scratchpad-lock.sh'

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
  [[ "$output" == *"PASS: acquired lock despite leftover plain file"* ]]
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

@test "session-lock: lock file is removed after release (lock.sh primitive)" {
  # session-tracker now uses the shared lock.sh primitive (#706) — there is no
  # per-strategy state to clear (the flock/mkdir mismatch #148 guarded against
  # cannot occur with a single primitive). The post-release invariant is simply
  # that the lock file is gone, so a subsequent acquire can re-link it.
  run bash -c "
    export SESSION_STATE_FILE='${RITE_TEST_TMPDIR}/test-session.json'
    source '${RITE_LIB_DIR}/utils/session-tracker.sh'

    _acquire_session_lock
    [ -e \"\${SESSION_STATE_FILE}.lock\" ] || { echo 'FAIL: lock file missing after acquire'; exit 1; }

    _release_session_lock
    if [ -e \"\${SESSION_STATE_FILE}.lock\" ]; then
      echo 'FAIL: lock file still present after release'
      exit 1
    fi
    echo 'PASS: lock file removed after release'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: lock file removed after release"* ]]
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
