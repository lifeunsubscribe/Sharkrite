#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh, lib/utils/lock.sh
# sharkrite-gate-serial — flaked under --jobs 8 (2026-07 audit: process-group/signal,
# concurrent-write, and timeout-race tests need the serial group)
# tests/regression/persist-approval-state-across-runs.bats
#
# Regression test for issue #169: Persist approval/notification state across runs.
#
# Problem: approved_blockers and sent_notifications were stored only in
# /tmp/rite-session-state-*.json (SESSION_STATE_FILE).  If /tmp was cleared
# (reboot, OS cleanup), a subsequent `rite N` invocation would create a fresh
# session file and lose all recorded approvals and notifications, forcing the
# user to re-approve blockers they had already approved.
#
# Fix: add_approved_blocker / add_sent_notification now ALSO write to a durable
# file at ${RITE_STATE_DIR}/approval-state.json.  has_approved_blocker /
# has_sent_notification check both sources, so approvals survive even when the
# /tmp session file is absent.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_NAME="test-project"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  export SESSION_STATE_FILE="$RITE_TEST_TMPDIR/rite-session-state.json"

  mkdir -p "$RITE_TEST_TMPDIR/.rite/state"

  source "$RITE_LIB_DIR/utils/session-tracker.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
  init_session "supervised"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test: add_approved_blocker writes to the durable file
# ---------------------------------------------------------------------------

@test "add_approved_blocker writes to durable approval-state.json" {
  add_approved_blocker "42" "critical_issues"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  [ -f "$approval_file" ] || {
    echo "FAIL: durable approval-state.json was not created"
    return 1
  }

  local found
  found=$(jq -r '.approved_blockers | index("42:critical_issues") != null' "$approval_file")
  [ "$found" = "true" ] || {
    echo "FAIL: '42:critical_issues' not found in durable approval-state.json"
    cat "$approval_file"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test: add_sent_notification writes to the durable file
# ---------------------------------------------------------------------------

@test "add_sent_notification writes to durable approval-state.json" {
  add_sent_notification "42" "blocker:credentials_expired"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  [ -f "$approval_file" ] || {
    echo "FAIL: durable approval-state.json was not created"
    return 1
  }

  local found
  found=$(jq -r '.sent_notifications | index("42:blocker:credentials_expired") != null' "$approval_file")
  [ "$found" = "true" ] || {
    echo "FAIL: '42:blocker:credentials_expired' not found in durable approval-state.json"
    cat "$approval_file"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test: has_approved_blocker returns true after SESSION_STATE_FILE is removed
#       (simulates /tmp cleanup between runs — the key regression scenario)
# ---------------------------------------------------------------------------

@test "has_approved_blocker survives SESSION_STATE_FILE deletion (cross-run persistence)" {
  # Record an approval in the first "run"
  add_approved_blocker "42" "critical_issues"

  # Simulate /tmp cleanup or start of a new run: remove the session file
  rm -f "$SESSION_STATE_FILE"

  # has_approved_blocker must still return true via the durable file
  if ! has_approved_blocker "42" "critical_issues"; then
    echo "REGRESSION (issue #169): approval lost when SESSION_STATE_FILE deleted"
    echo "Expected has_approved_blocker to check .rite/state/approval-state.json"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test: has_sent_notification returns true after SESSION_STATE_FILE is removed
# ---------------------------------------------------------------------------

@test "has_sent_notification survives SESSION_STATE_FILE deletion (cross-run persistence)" {
  # Record a notification in the first "run"
  add_sent_notification "42" "blocker:credentials_expired"

  # Simulate /tmp cleanup: remove the session file
  rm -f "$SESSION_STATE_FILE"

  # has_sent_notification must still return true via the durable file
  if ! has_sent_notification "42" "blocker:credentials_expired"; then
    echo "REGRESSION (issue #169): notification record lost when SESSION_STATE_FILE deleted"
    echo "Expected has_sent_notification to check .rite/state/approval-state.json"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test: has_approved_blocker still returns false for unapproved blockers even
#       when the durable file exists (no false positives)
# ---------------------------------------------------------------------------

@test "has_approved_blocker returns false for unapproved blocker (no false positives)" {
  add_approved_blocker "42" "critical_issues"

  # A different blocker/issue should NOT be considered approved
  if has_approved_blocker "43" "critical_issues"; then
    echo "FAIL: has_approved_blocker returned true for issue 43 (only 42 was approved)"
    return 1
  fi

  if has_approved_blocker "42" "database_migration"; then
    echo "FAIL: has_approved_blocker returned true for database_migration (only critical_issues was approved)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test: has_sent_notification returns false for unsent notification types
# ---------------------------------------------------------------------------

@test "has_sent_notification returns false for unsent notification (no false positives)" {
  add_sent_notification "42" "blocker:credentials_expired"

  # Different issue or type must not match
  if has_sent_notification "99" "blocker:credentials_expired"; then
    echo "FAIL: has_sent_notification returned true for issue 99 (only 42 was recorded)"
    return 1
  fi

  if has_sent_notification "42" "blocker:critical_issues"; then
    echo "FAIL: has_sent_notification returned true for critical_issues (only credentials_expired was recorded)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test: Multiple approvals are all persisted to the durable file
# ---------------------------------------------------------------------------

@test "multiple approvals all written to durable approval-state.json" {
  add_approved_blocker "10" "critical_issues"
  add_approved_blocker "11" "database_migration"
  add_approved_blocker "12" "credentials_expired"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"

  for key in "10:critical_issues" "11:database_migration" "12:credentials_expired"; do
    local found
    found=$(jq -r ".approved_blockers | index(\"${key}\") != null" "$approval_file")
    [ "$found" = "true" ] || {
      echo "FAIL: key '${key}' not found in durable approval-state.json"
      cat "$approval_file"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Test: init_session followed by has_approved_blocker picks up durable state
#       (simulates the cleanup_session → init_session sequence described in #169)
# ---------------------------------------------------------------------------

@test "approval survives cleanup_session followed by init_session (issue #169 sequence)" {
  # First run: record an approval
  add_approved_blocker "42" "critical_issues"

  # Simulate cleanup_session (deletes /tmp session file) + new run (fresh init)
  cleanup_session >/dev/null 2>&1 || true
  init_session "supervised"

  # The durable file must still hold the approval
  if ! has_approved_blocker "42" "critical_issues"; then
    echo "REGRESSION (issue #169): approval lost after cleanup_session → init_session"
    echo "Expected durable .rite/state/approval-state.json to be consulted"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test: _get_approval_state_file falls back to /tmp when RITE_STATE_DIR unset
# ---------------------------------------------------------------------------

@test "_get_approval_state_file falls back to /tmp when RITE_STATE_DIR is unset" {
  local saved_state_dir="${RITE_STATE_DIR:-}"
  unset RITE_STATE_DIR

  local path
  path="$(_get_approval_state_file)"

  # Must contain /tmp and the project name (not crash or return empty)
  [[ "$path" == /tmp/* ]] || {
    echo "FAIL: fallback path '${path}' does not start with /tmp/"
    return 1
  }

  # Restore
  export RITE_STATE_DIR="$saved_state_dir"
}

# ---------------------------------------------------------------------------
# Test: durable file is valid JSON after multiple concurrent writes
#       (ensure _add_to_approval_file under lock doesn't corrupt)
# ---------------------------------------------------------------------------

@test "concurrent add_approved_blocker calls produce valid durable JSON" {
  # Two concurrent writers is the minimum that exercises the durable-file lock's
  # mutual exclusion: without the lock, both read the same base state and the
  # second mv clobbers the first, dropping an approval — caught below by the
  # "all approvals present" check. The shared-lock contention (each acquire polls
  # at 1s granularity, session-tracker.sh) scales with writer count; 4 writers
  # blew the serial-group budget under --jobs 8 saturation, so keep this at the
  # 2-writer floor. The durable lock's correctness itself is proven in lock.sh
  # (#706); this is a regression guard, not a discovery stress test. Issue #878.
  #
  # Implementation note: each worker is launched as a separate `bash` process
  # (not a `( ) &` subshell) so that each gets its own $$ / $BASHPID. A
  # subshell inherits the parent's $$, which causes lock.sh's PID-based
  # liveness check to treat both workers as the same process — the loser sees
  # the lock holder's PID = its own $$ and incorrectly steals the live lock,
  # racing to produce corrupt JSON or causing a 120s lock-timeout.
  local num_processes=2
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  local worker_script="$RITE_TEST_TMPDIR/worker.sh"
  mkdir -p "$exit_codes_dir"

  # Write a standalone worker script so each invocation gets its own PID.
  cat > "$worker_script" <<WORKER_EOF
#!/bin/bash
set -euo pipefail
WORKER_INDEX="\$1"
export SESSION_STATE_FILE="$RITE_TEST_TMPDIR/rite-session-state-\${WORKER_INDEX}.json"
export RITE_LIB_DIR="$RITE_LIB_DIR"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-test-project}"
# Source session-tracker fresh (new process, no inherited guard state).
source "\$RITE_LIB_DIR/utils/session-tracker.sh"
init_session "supervised"
add_approved_blocker "issue-\${WORKER_INDEX}" "blocker-\${WORKER_INDEX}"
echo \$? > "$exit_codes_dir/process_\${WORKER_INDEX}.exit"
WORKER_EOF
  chmod +x "$worker_script"

  # Launch each worker as a separate process (own $$) so lock.sh PID checks work.
  for i in $(seq 1 $num_processes); do
    bash "$worker_script" "$i" &
  done

  wait

  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ] || {
      echo "FAIL: worker $i did not write exit code (may have crashed before completion)"
      return 1
    }
    local code
    code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$code" -eq 0 ] || {
      echo "FAIL: process $i exited with code $code"
      return 1
    }
  done

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  jq empty "$approval_file" 2>/dev/null || {
    echo "FAIL: durable approval-state.json is not valid JSON after concurrent writes"
    cat "$approval_file"
    return 1
  }

  # All approvals must be present
  for i in $(seq 1 $num_processes); do
    local found
    found=$(jq -r ".approved_blockers | index(\"issue-${i}:blocker-${i}\") != null" "$approval_file")
    [ "$found" = "true" ] || {
      echo "FAIL: approval for issue-${i}:blocker-${i} not found in durable file"
      cat "$approval_file"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Regression guard (approval-lock atomic migration): the approval lock must use
# the shared lock.sh ln+token primitive, NOT the old hand-rolled mkdir+sleep-1
# mutex. That mutex's create→PID-write window let a CPU-starved holder's live
# lock be reclaimed by a waiter after a 1s grace, breaking mutual exclusion and
# hanging concurrent add_approved_blocker under gate --jobs 8 load past the 120s
# bats timeout (blocked #1007 and #1008, 2026-07). This is the same #706
# migration the SESSION lock already has.
# ---------------------------------------------------------------------------
@test "source: _acquire_approval_lock delegates to lock_acquire (atomic primitive)" {
  _tracker="${BATS_TEST_DIRNAME}/../../lib/utils/session-tracker.sh"
  # Extract the function body and assert it calls lock_acquire.
  _body=$(awk '/^_acquire_approval_lock\(\)/{f=1} f{print} f&&/^}$/{exit}' "$_tracker")
  echo "$_body" | grep -q 'lock_acquire ' || {
    echo "FAIL: _acquire_approval_lock does not delegate to lock_acquire" >&2
    echo "      It must use the shared lock.sh primitive, not a hand-rolled lock." >&2
    return 1
  }
}

@test "source: _acquire_approval_lock has NO hand-rolled mkdir-spin mutex" {
  _tracker="${BATS_TEST_DIRNAME}/../../lib/utils/session-tracker.sh"
  _body=$(awk '/^_acquire_approval_lock\(\)/{f=1} f{print} f&&/^}$/{exit}' "$_tracker")
  # The vulnerable pattern was `while ! mkdir "$lockdir"` + a separate pid write.
  ! echo "$_body" | grep -qE 'while ! mkdir|mktemp .*lockdir|pid\.XXXXXX' || {
    echo "FAIL: hand-rolled mkdir-spin mutex reintroduced in _acquire_approval_lock" >&2
    echo "      The create→PID-write window hangs concurrent workers under load." >&2
    return 1
  }
}

@test "source: _release_approval_lock delegates to lock_release" {
  _tracker="${BATS_TEST_DIRNAME}/../../lib/utils/session-tracker.sh"
  _body=$(awk '/^_release_approval_lock\(\)/{f=1} f{print} f&&/^}$/{exit}' "$_tracker")
  echo "$_body" | grep -q 'lock_release ' || {
    echo "FAIL: _release_approval_lock does not delegate to lock_release" >&2
    return 1
  }
}
