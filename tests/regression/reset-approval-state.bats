#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/blocker-rules.sh
# tests/regression/reset-approval-state.bats
#
# Regression test for issue #255: Reset durable approval state for blockers.
#
# Problem: Users who recorded a false approval (e.g., mistakenly bypassed a
# CRITICAL blocker) had no supported recovery path. The only option was manual
# deletion of .rite/state/approval-state.json, which is undocumented and
# destroys all approvals, not just the incorrect one.
#
# Fix: Three new functions in session-tracker.sh provide targeted reset paths:
#   - reset_approved_blocker(issue, blocker_type)  — remove one specific approval
#   - reset_approved_blockers_for_issue(issue)      — remove all approvals for issue
#   - reset_all_approved_blockers()                 — clear entire approved_blockers array
#
# All three update both the in-memory session file AND the durable
# approval-state.json so the reset takes effect in the current session and
# all subsequent runs.

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
# reset_approved_blocker: removes a single specific approval
# ---------------------------------------------------------------------------

@test "reset_approved_blocker removes specific approval from durable file" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "42" "database_migration"

  reset_approved_blocker "42" "critical_issues"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"

  # The removed entry must be gone
  local found_removed
  found_removed=$(jq -r '.approved_blockers | index("42:critical_issues") != null' "$approval_file")
  [ "$found_removed" = "false" ] || {
    echo "FAIL: '42:critical_issues' still present in durable file after reset"
    cat "$approval_file"
    return 1
  }

  # The other entry must remain
  local found_kept
  found_kept=$(jq -r '.approved_blockers | index("42:database_migration") != null' "$approval_file")
  [ "$found_kept" = "true" ] || {
    echo "FAIL: '42:database_migration' was removed but should have been kept"
    cat "$approval_file"
    return 1
  }
}

@test "reset_approved_blocker removes specific approval from in-memory session file" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "42" "database_migration"

  reset_approved_blocker "42" "critical_issues"

  # The removed entry must be gone from in-memory file
  local found_removed
  found_removed=$(jq -r '.approved_blockers | index("42:critical_issues") != null' "$SESSION_STATE_FILE")
  [ "$found_removed" = "false" ] || {
    echo "FAIL: '42:critical_issues' still present in session file after reset"
    cat "$SESSION_STATE_FILE"
    return 1
  }

  # The other entry must remain
  local found_kept
  found_kept=$(jq -r '.approved_blockers | index("42:database_migration") != null' "$SESSION_STATE_FILE")
  [ "$found_kept" = "true" ] || {
    echo "FAIL: '42:database_migration' was removed from session file but should have been kept"
    cat "$SESSION_STATE_FILE"
    return 1
  }
}

@test "has_approved_blocker returns false after reset_approved_blocker" {
  add_approved_blocker "42" "critical_issues"

  # Confirm it was recorded
  if ! has_approved_blocker "42" "critical_issues"; then
    echo "FAIL: setup failure — approval not recorded"
    return 1
  fi

  reset_approved_blocker "42" "critical_issues"

  # Must no longer be approved
  if has_approved_blocker "42" "critical_issues"; then
    echo "REGRESSION (issue #255): has_approved_blocker returned true after reset"
    return 1
  fi
}

@test "reset_approved_blocker is a no-op when the key does not exist" {
  add_approved_blocker "42" "critical_issues"

  # Reset a key that was never recorded — must not fail or corrupt the file
  reset_approved_blocker "99" "database_migration"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  local found
  found=$(jq -r '.approved_blockers | index("42:critical_issues") != null' "$approval_file")
  [ "$found" = "true" ] || {
    echo "FAIL: '42:critical_issues' was removed by a no-op reset that targeted a different key"
    cat "$approval_file"
    return 1
  }
}

@test "reset_approved_blocker does not affect entries for other issues" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "43" "critical_issues"
  add_approved_blocker "44" "database_migration"

  reset_approved_blocker "42" "critical_issues"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"

  # Issues 43 and 44 must be unaffected
  for key in "43:critical_issues" "44:database_migration"; do
    local found
    found=$(jq -r ".approved_blockers | index(\"${key}\") != null" "$approval_file")
    [ "$found" = "true" ] || {
      echo "FAIL: '${key}' was incorrectly removed by reset targeting '42:critical_issues'"
      cat "$approval_file"
      return 1
    }
  done
}

@test "reset_approved_blocker works when SESSION_STATE_FILE does not exist" {
  add_approved_blocker "42" "critical_issues"

  # Simulate a fresh run with no session file
  rm -f "$SESSION_STATE_FILE"

  # Must not crash even with no session file
  reset_approved_blocker "42" "critical_issues"

  # The durable file must still reflect the reset
  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  local found
  found=$(jq -r '.approved_blockers | index("42:critical_issues") != null' "$approval_file")
  [ "$found" = "false" ] || {
    echo "FAIL: '42:critical_issues' still present in durable file after reset (no session file)"
    cat "$approval_file"
    return 1
  }
}

# ---------------------------------------------------------------------------
# reset_approved_blockers_for_issue: removes all approvals for one issue
# ---------------------------------------------------------------------------

@test "reset_approved_blockers_for_issue removes all approvals for the issue" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "42" "database_migration"
  add_approved_blocker "42" "credentials_expired"

  reset_approved_blockers_for_issue "42"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"

  for key in "42:critical_issues" "42:database_migration" "42:credentials_expired"; do
    local found
    found=$(jq -r ".approved_blockers | index(\"${key}\") != null" "$approval_file")
    [ "$found" = "false" ] || {
      echo "FAIL: '${key}' still present after reset_approved_blockers_for_issue 42"
      cat "$approval_file"
      return 1
    }
  done
}

@test "reset_approved_blockers_for_issue does not affect other issues" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "43" "critical_issues"
  add_approved_blocker "43" "database_migration"

  reset_approved_blockers_for_issue "42"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"

  for key in "43:critical_issues" "43:database_migration"; do
    local found
    found=$(jq -r ".approved_blockers | index(\"${key}\") != null" "$approval_file")
    [ "$found" = "true" ] || {
      echo "FAIL: '${key}' was incorrectly removed when only issue 42 was targeted"
      cat "$approval_file"
      return 1
    }
  done
}

@test "has_approved_blocker returns false for all blockers after reset_approved_blockers_for_issue" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "42" "database_migration"

  reset_approved_blockers_for_issue "42"

  if has_approved_blocker "42" "critical_issues"; then
    echo "REGRESSION (issue #255): has_approved_blocker returned true for critical_issues after issue reset"
    return 1
  fi

  if has_approved_blocker "42" "database_migration"; then
    echo "REGRESSION (issue #255): has_approved_blocker returned true for database_migration after issue reset"
    return 1
  fi
}

@test "reset_approved_blockers_for_issue is a no-op when issue has no approvals" {
  add_approved_blocker "43" "critical_issues"

  # Reset for issue 42 which has no approvals — must not fail or corrupt
  reset_approved_blockers_for_issue "42"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  local found
  found=$(jq -r '.approved_blockers | index("43:critical_issues") != null' "$approval_file")
  [ "$found" = "true" ] || {
    echo "FAIL: '43:critical_issues' was removed by no-op reset targeting issue 42"
    cat "$approval_file"
    return 1
  }
}

@test "reset_approved_blockers_for_issue also clears in-memory session file" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "42" "database_migration"

  reset_approved_blockers_for_issue "42"

  # Both entries must be gone from the in-memory session file
  for key in "42:critical_issues" "42:database_migration"; do
    local found
    found=$(jq -r ".approved_blockers | index(\"${key}\") != null" "$SESSION_STATE_FILE")
    [ "$found" = "false" ] || {
      echo "FAIL: '${key}' still present in session file after reset_approved_blockers_for_issue 42"
      cat "$SESSION_STATE_FILE"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# reset_all_approved_blockers: clears the entire approved_blockers array
# ---------------------------------------------------------------------------

@test "reset_all_approved_blockers clears all approvals from durable file" {
  add_approved_blocker "10" "critical_issues"
  add_approved_blocker "11" "database_migration"
  add_approved_blocker "12" "credentials_expired"

  reset_all_approved_blockers

  local approval_file="${RITE_STATE_DIR}/approval-state.json"

  local count
  count=$(jq '.approved_blockers | length' "$approval_file")
  [ "$count" -eq 0 ] || {
    echo "FAIL: approved_blockers not empty after reset_all_approved_blockers (count: $count)"
    cat "$approval_file"
    return 1
  }
}

@test "reset_all_approved_blockers also clears in-memory session file" {
  add_approved_blocker "10" "critical_issues"
  add_approved_blocker "11" "database_migration"

  reset_all_approved_blockers

  local count
  count=$(jq '.approved_blockers | length' "$SESSION_STATE_FILE")
  [ "$count" -eq 0 ] || {
    echo "FAIL: approved_blockers not empty in session file after reset_all_approved_blockers (count: $count)"
    cat "$SESSION_STATE_FILE"
    return 1
  }
}

@test "has_approved_blocker returns false for all blockers after reset_all_approved_blockers" {
  add_approved_blocker "10" "critical_issues"
  add_approved_blocker "11" "database_migration"
  add_approved_blocker "12" "credentials_expired"

  reset_all_approved_blockers

  for issue in "10" "11" "12"; do
    if has_approved_blocker "$issue" "critical_issues"; then
      echo "REGRESSION (issue #255): has_approved_blocker returned true for $issue after global reset"
      return 1
    fi
  done

  if has_approved_blocker "11" "database_migration"; then
    echo "REGRESSION (issue #255): has_approved_blocker returned true for 11:database_migration after global reset"
    return 1
  fi
}

@test "reset_all_approved_blockers is a no-op when no approvals exist" {
  # No approvals recorded — must not fail or crash
  reset_all_approved_blockers

  # Must not have crashed; approval file may not even exist
  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  if [ -f "$approval_file" ]; then
    jq empty "$approval_file" 2>/dev/null || {
      echo "FAIL: approval-state.json is not valid JSON after no-op reset"
      cat "$approval_file"
      return 1
    }
  fi
}

@test "reset_all_approved_blockers preserves sent_notifications (only approvals cleared)" {
  add_approved_blocker "42" "critical_issues"
  add_sent_notification "42" "blocker:credentials_expired"

  reset_all_approved_blockers

  # Approved blockers must be gone
  local count
  count=$(jq '.approved_blockers | length' "${RITE_STATE_DIR}/approval-state.json")
  [ "$count" -eq 0 ] || {
    echo "FAIL: approved_blockers not empty after reset"
    return 1
  }

  # Sent notifications must be preserved
  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  local notif_found
  notif_found=$(jq -r '.sent_notifications | index("42:blocker:credentials_expired") != null' "$approval_file")
  [ "$notif_found" = "true" ] || {
    echo "FAIL: sent_notifications were incorrectly cleared by reset_all_approved_blockers"
    cat "$approval_file"
    return 1
  }
}

@test "reset_all_approved_blockers works when SESSION_STATE_FILE does not exist" {
  add_approved_blocker "42" "critical_issues"

  # Remove session file to simulate a fresh run
  rm -f "$SESSION_STATE_FILE"

  # Must not crash; must still clear the durable file
  reset_all_approved_blockers

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  local count
  count=$(jq '.approved_blockers | length' "$approval_file")
  [ "$count" -eq 0 ] || {
    echo "FAIL: approved_blockers not empty in durable file after reset (no session file)"
    cat "$approval_file"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Durable file integrity: resets must produce valid JSON
# ---------------------------------------------------------------------------

@test "approval-state.json remains valid JSON after selective reset" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "43" "database_migration"

  reset_approved_blocker "42" "critical_issues"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  jq empty "$approval_file" 2>/dev/null || {
    echo "FAIL: approval-state.json is not valid JSON after selective reset"
    cat "$approval_file"
    return 1
  }
}

@test "approval-state.json remains valid JSON after issue-scoped reset" {
  add_approved_blocker "42" "critical_issues"
  add_approved_blocker "42" "database_migration"
  add_approved_blocker "43" "critical_issues"

  reset_approved_blockers_for_issue "42"

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  jq empty "$approval_file" 2>/dev/null || {
    echo "FAIL: approval-state.json is not valid JSON after issue-scoped reset"
    cat "$approval_file"
    return 1
  }
}

@test "approval-state.json remains valid JSON after global reset" {
  add_approved_blocker "42" "critical_issues"
  add_sent_notification "42" "blocker:test_failure"

  reset_all_approved_blockers

  local approval_file="${RITE_STATE_DIR}/approval-state.json"
  jq empty "$approval_file" 2>/dev/null || {
    echo "FAIL: approval-state.json is not valid JSON after global reset"
    cat "$approval_file"
    return 1
  }
}
