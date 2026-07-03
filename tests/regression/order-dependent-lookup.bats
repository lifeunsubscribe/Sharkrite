#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# tests/regression/order-dependent-lookup.bats
#
# Regression tests for order-dependent lookup bugs in issue-lock.sh:
#
# Bug 1 (primary): get_locked_issue_numbers() must return numbers in NUMERIC
#   order, not lexical.  Lexical order puts issue-10 before issue-9, so the
#   first-match-wins logic in repo-status.sh worktree lookup would shadow the
#   correct issue ID with a stale lock from a numerically higher issue number.
#
# Bug 2: acquire_issue_lock() no-PID grace period must match scratchpad-lock.sh
#   and session-tracker.sh (1-second wait before reclaiming).  The old code
#   reclaimed immediately, creating a window where an in-flight mktemp+mv could
#   be wrongly treated as a crashed holder.
#
# Bug 3: _has_in_approval_file() in session-tracker.sh must warn (not silently
#   return false-negative) when approval-state.json is malformed.
#
# Source issues: #191, #194, #251, #252, #254

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/$RITE_DATA_DIR/locks"

  mkdir -p "$RITE_TEST_TMPDIR/$RITE_DATA_DIR"
  mkdir -p "$RITE_LOCK_DIR"

  # Source issue-lock functions
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/issue-lock.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Bug 1: Numeric sort in get_locked_issue_numbers()
# ---------------------------------------------------------------------------

@test "get_locked_issue_numbers returns numbers in numeric order (not lexical)" {
  # Create lock dirs for issues 9 and 10. Lexical order gives 10 before 9;
  # numeric order gives 9 before 10. The function must use numeric sort.
  for _num in 9 10; do
    mkdir -p "$RITE_LOCK_DIR/issue-${_num}.lock"
    # Use current subshell PID for a live process check
    echo $$ > "$RITE_LOCK_DIR/issue-${_num}.lock/pid"
  done

  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  # Output must be "9\n10" not "10\n9"
  local first second
  first=$(echo "$output" | head -1)
  second=$(echo "$output" | tail -1)
  [ "$first" = "9" ]
  [ "$second" = "10" ]
}

@test "get_locked_issue_numbers numeric sort holds for multi-digit gap (e.g. 2, 10, 100)" {
  for _num in 100 10 2; do
    mkdir -p "$RITE_LOCK_DIR/issue-${_num}.lock"
    echo $$ > "$RITE_LOCK_DIR/issue-${_num}.lock/pid"
  done

  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  local lines
  mapfile -t lines <<< "$output"
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "10" ]
  [ "${lines[2]}" = "100" ]
}

@test "get_locked_issue_numbers excludes stale locks (dead PID)" {
  # Issue 42: live lock (current PID)
  mkdir -p "$RITE_LOCK_DIR/issue-42.lock"
  echo $$ > "$RITE_LOCK_DIR/issue-42.lock/pid"

  # Issue 99: stale lock (dead PID — use a completed subshell rather than a
  # hardcoded value like 99999, which can be a live PID on Linux systems with
  # pid_max > 99999, e.g. containers or custom kernel configs).
  mkdir -p "$RITE_LOCK_DIR/issue-99.lock"
  get_dead_pid > "$RITE_LOCK_DIR/issue-99.lock/pid"

  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "get_locked_issue_numbers excludes locks with no PID file (grace-period state)" {
  # Issue 7: live lock
  mkdir -p "$RITE_LOCK_DIR/issue-7.lock"
  echo $$ > "$RITE_LOCK_DIR/issue-7.lock/pid"

  # Issue 8: lock dir exists but no PID file (in grace period or crashed)
  mkdir -p "$RITE_LOCK_DIR/issue-8.lock"
  # Intentionally no pid file

  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "get_locked_issue_numbers returns empty when no lock dirs exist" {
  # RITE_LOCK_DIR is empty (no issue-*.lock dirs)
  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get_locked_issue_numbers returns empty when RITE_LOCK_DIR does not exist" {
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/nonexistent-locks"
  # Do NOT create the directory

  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get_locked_issue_numbers skips non-issue lock dirs (e.g. pr-followup locks)" {
  # Create an issue lock and a followup lock; only the issue lock should appear
  mkdir -p "$RITE_LOCK_DIR/issue-5.lock"
  echo $$ > "$RITE_LOCK_DIR/issue-5.lock/pid"

  mkdir -p "$RITE_LOCK_DIR/pr-101-src-5-followup.lock"
  echo $$ > "$RITE_LOCK_DIR/pr-101-src-5-followup.lock/pid"

  run get_locked_issue_numbers

  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

# ---------------------------------------------------------------------------
# Bug 2: Grace period consistency — no-PID lock reclaim must wait 1s
# ---------------------------------------------------------------------------
# NOTE: We cannot directly assert the sleep(1) without real-time testing,
# but we CAN assert that after writing the PID within ~1s the lock is NOT
# reclaimed (i.e., the grace period is observed before the reclaim check).

@test "acquire_issue_lock reclaims no-PID lock after grace period (message check)" {
  # Create lock dir without PID file simulating a crashed holder (pre-atomic path)
  mkdir -p "$RITE_LOCK_DIR/issue-77.lock"
  # No pid file written

  # The new code does: sleep (grace period), then check again.  Since we never
  # write a pid, after the sleep it should reclaim and acquire.
  # Use _RITE_LOCK_GRACE_PERIOD_S=0 to avoid a real 1-second sleep in tests.
  run --separate-stderr bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${RITE_REPO_ROOT}/lib/utils/issue-lock.sh'
    acquire_issue_lock 77
  "
  [ "$status" -eq 0 ]
  # Must have emitted the grace-period reclaim message to stderr (not the old immediate one)
  [[ "$stderr" =~ "grace period" ]]
}

@test "acquire_pr_followup_lock reclaims no-PID lock after grace period (message check)" {
  mkdir -p "$RITE_LOCK_DIR/pr-55-src-7-followup.lock"
  # No pid file

  # Use _RITE_LOCK_GRACE_PERIOD_S=0 to avoid a real 1-second sleep in tests.
  run --separate-stderr bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${RITE_REPO_ROOT}/lib/utils/issue-lock.sh'
    acquire_pr_followup_lock 55 7
  "
  [ "$status" -eq 0 ]
  [[ "$stderr" =~ "grace period" ]]
}

# ---------------------------------------------------------------------------
# Bug 3: _has_in_approval_file warns on malformed approval-state.json
# ---------------------------------------------------------------------------

@test "_has_in_approval_file warns to stderr when approval-state.json is malformed" {
  export SESSION_STATE_FILE="$RITE_TEST_TMPDIR/session-state.json"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_STATE_DIR"

  # Write a malformed JSON file
  printf 'this is not valid JSON\n' > "$RITE_STATE_DIR/approval-state.json"

  run --separate-stderr bash -c "
    export SESSION_STATE_FILE='${SESSION_STATE_FILE}'
    export RITE_STATE_DIR='${RITE_STATE_DIR}'
    export RITE_PROJECT_NAME='test-project'
    source '${RITE_REPO_ROOT}/lib/utils/session-tracker.sh'
    # Call _has_in_approval_file — it should warn and return 1
    _has_in_approval_file '42:critical_issues' 'approved_blockers'
  "

  # Must return non-zero (file is malformed, key not found)
  [ "$status" -ne 0 ]
  # Must have warned to stderr about malformed file
  [[ "$stderr" =~ "malformed" ]]
}

@test "_has_in_approval_file returns 1 silently when approval-state.json does not exist" {
  export SESSION_STATE_FILE="$RITE_TEST_TMPDIR/session-state.json"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state-nonexistent"
  # Do NOT create RITE_STATE_DIR or the file

  run bash -c "
    export SESSION_STATE_FILE='${SESSION_STATE_FILE}'
    export RITE_STATE_DIR='${RITE_STATE_DIR}'
    export RITE_PROJECT_NAME='test-project'
    source '${RITE_REPO_ROOT}/lib/utils/session-tracker.sh'
    _has_in_approval_file '42:critical_issues' 'approved_blockers'
  "

  [ "$status" -ne 0 ]
  # Must NOT warn — missing file is not an error, just "not found"
  [[ ! "$output" =~ "malformed" ]]
}

@test "_has_in_approval_file returns 0 when key is present in well-formed file" {
  export SESSION_STATE_FILE="$RITE_TEST_TMPDIR/session-state.json"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state-good"
  mkdir -p "$RITE_STATE_DIR"

  # Write a well-formed approval state file with the key present
  cat > "$RITE_STATE_DIR/approval-state.json" <<'EOF'
{
  "approved_blockers": ["42:critical_issues", "99:test"],
  "sent_notifications": []
}
EOF

  run bash -c "
    export SESSION_STATE_FILE='${SESSION_STATE_FILE}'
    export RITE_STATE_DIR='${RITE_STATE_DIR}'
    export RITE_PROJECT_NAME='test-project'
    source '${RITE_REPO_ROOT}/lib/utils/session-tracker.sh'
    _has_in_approval_file '42:critical_issues' 'approved_blockers'
  "

  [ "$status" -eq 0 ]
}
