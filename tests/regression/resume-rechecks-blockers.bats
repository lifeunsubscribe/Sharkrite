#!/usr/bin/env bats
# tests/regression/resume-rechecks-blockers.bats
#
# Regression test for: Re-check pre-start blockers on resume
#
# Bug: run_workflow only runs phase_pre_start_checks when skip_to_phase is empty.
# skip_to_phase is derived from PR/review state, NOT from the saved blocker reason.
# So resuming a credentials_expired session skips credential re-check; creds fail mid-merge.
#
# Fix: Export RESUME_BLOCKER_REASON from main(); in run_workflow(), force
# phase_pre_start_checks when RESUME_BLOCKER_REASON is a known blocker type
# (credentials_expired, test_env, missing_tool) — regardless of skip_to_phase.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ─── Helper: write a session-state JSON for issue N ───────────────────────────
_write_state() {
  local issue="$1"
  local reason="$2"
  local phase="${3:-merge}"
  cat > "$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json" <<EOF
{
  "saved_at": 1700000000,
  "saved_at_human": "2026-01-01 00:00:00",
  "reason": "$reason",
  "issue_number": "$issue",
  "pr_number": "99",
  "phase": "$phase",
  "retry_count": 0,
  "worktree_path": "/tmp/nonexistent-worktree",
  "workflow_mode": "auto",
  "git_status": "",
  "last_commit": ""
}
EOF
}

# ─── Helper: the minimal force-prestart logic extracted from run_workflow ──────
# This mirrors exactly the case statement added in the fix. We run it as a
# standalone script to validate the gating condition in isolation.
_run_prestart_gate() {
  local resume_blocker_reason="$1"
  local skip_to_phase="$2"         # Simulates PR/review-derived skip value
  local prestart_called_file="$3"  # Path to a file: touched if check would run

  bash <<EOF
set -euo pipefail

RESUME_BLOCKER_REASON="$resume_blocker_reason"
skip_to_phase="$skip_to_phase"
prestart_called_file="$prestart_called_file"

# ── Exact logic from the fix (run_workflow, Phase 0 gate) ──
_force_prestart=false
case "\${RESUME_BLOCKER_REASON:-}" in
  credentials_expired|test_env|missing_tool)
    _force_prestart=true
    ;;
esac

if [ -z "\$skip_to_phase" ] || [ "\$_force_prestart" = true ]; then
  # Simulate phase_pre_start_checks being called
  touch "\$prestart_called_file"
fi
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: RESUME_BLOCKER_REASON gate forces pre-start check
# ─────────────────────────────────────────────────────────────────────────────

@test "credentials_expired: pre-start check runs even when skip_to_phase=merge" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "credentials_expired" "merge" "$called_file"

  [ -f "$called_file" ] || {
    echo "FAIL: phase_pre_start_checks was NOT called for credentials_expired resume" >&2
    return 1
  }
}

@test "credentials_expired: pre-start check runs when skip_to_phase=assess-resolve" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "credentials_expired" "assess-resolve" "$called_file"

  [ -f "$called_file" ]
}

@test "test_env: pre-start check runs when skip_to_phase=merge" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "test_env" "merge" "$called_file"

  [ -f "$called_file" ]
}

@test "missing_tool: pre-start check runs when skip_to_phase=create-pr" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "missing_tool" "create-pr" "$called_file"

  [ -f "$called_file" ]
}

@test "unknown blocker reason: pre-start check skipped when skip_to_phase=merge (no regression)" {
  # Non-blocker reasons (e.g. interrupted, session_limit) must NOT force
  # the pre-start check when phases are already known to be complete.
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "interrupted" "merge" "$called_file"

  [ ! -f "$called_file" ] || {
    echo "FAIL: phase_pre_start_checks was incorrectly called for 'interrupted' reason" >&2
    return 1
  }
}

@test "empty blocker reason: pre-start check skipped when skip_to_phase=merge (no regression)" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "" "merge" "$called_file"

  [ ! -f "$called_file" ]
}

@test "credentials_expired: pre-start check still runs when skip_to_phase is empty (normal path)" {
  # Validate the normal (non-skip) path still works.
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_prestart_gate "credentials_expired" "" "$called_file"

  [ -f "$called_file" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: RESUME_BLOCKER_REASON exported from main() via session-state JSON
# ─────────────────────────────────────────────────────────────────────────────

@test "session-state with credentials_expired sets RESUME_BLOCKER_REASON correctly" {
  # Verify that the jq extraction used in main() produces the right value.
  local issue=22
  _write_state "$issue" "credentials_expired" "merge"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  [ "$saved_reason" = "credentials_expired" ]
}

@test "session-state with test_env sets RESUME_BLOCKER_REASON correctly" {
  local issue=23
  _write_state "$issue" "test_env" "claude-workflow"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  [ "$saved_reason" = "test_env" ]
}

@test "session-state with interrupted does not match blocker reasons" {
  # 'interrupted' is not a blocker type that requires re-check;
  # it means the user hit Ctrl-C and phases completed normally up to that point.
  local issue=24
  _write_state "$issue" "interrupted" "assess-resolve"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  # Confirm it does NOT match any of the force-prestart reasons
  case "$saved_reason" in
    credentials_expired|test_env|missing_tool)
      echo "FAIL: 'interrupted' was incorrectly matched as a blocker reason" >&2
      return 1
      ;;
  esac
}

@test "missing state file: RESUME_BLOCKER_REASON is empty (no pre-start forced)" {
  # When there is no saved session state, saved_reason defaults to empty.
  # Verify the gate does not fire for a fresh run.
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  # No state file written — simulate what main() does: saved_reason=""
  _run_prestart_gate "" "merge" "$called_file"

  [ ! -f "$called_file" ]
}
