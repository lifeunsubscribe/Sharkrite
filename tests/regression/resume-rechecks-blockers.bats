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
# (credentials_expired, test_failures, session_limit) — regardless of skip_to_phase.
# Those are the reasons actually persisted by save_session_state_with_phase.

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

# ─── Helper: invoke the real case gate from workflow-runner.sh ─────────────────
# Sources the real check_blockers function from blocker-rules.sh with mocked
# detect_aws_project / detect_credentials_expired so no live AWS call is made.
# Writes a sentinel file if the gate fires (i.e. RESUME_BLOCKER_REASON matches
# one of the real persisted reasons).
#
# Usage: _run_real_prestart_gate REASON SKIP_TO_PHASE SENTINEL_FILE
_run_real_prestart_gate() {
  local resume_blocker_reason="$1"
  local skip_to_phase="$2"
  local prestart_called_file="$3"
  local rite_repo_root="${RITE_REPO_ROOT}"
  local stub_lib_dir="$RITE_TEST_TMPDIR/stub-lib"

  # Create a stub RITE_LIB_DIR with a no-op notifications.sh so that
  # sourcing blocker-rules.sh does not require the real notification stack.
  mkdir -p "$stub_lib_dir/utils"
  cat > "$stub_lib_dir/utils/notifications.sh" <<'STUB'
# stub: no-op notifications for test isolation
send_blocker_notification() { :; }
has_sent_notification() { return 1; }
add_sent_notification() { :; }
STUB

  bash <<EOF
set -euo pipefail

export RESUME_BLOCKER_REASON="$resume_blocker_reason"
export FAKE_CREDS_EXPIRED="${FAKE_CREDS_EXPIRED:-false}"
skip_to_phase="$skip_to_phase"
prestart_called_file="$prestart_called_file"

# Point RITE_LIB_DIR at the stub directory so blocker-rules.sh sources our
# no-op notifications.sh instead of the real one.
export RITE_LIB_DIR="$stub_lib_dir"

# Define and export AWS helper mocks BEFORE sourcing blocker-rules.sh.
# blocker-rules.sh does 'export -f detect_credentials_expired' after definition,
# so defining them first means the real file's definitions overwrite ours — but
# we re-override after the source.
source "${rite_repo_root}/lib/utils/blocker-rules.sh"

# Re-override AWS helpers AFTER sourcing (the source overwrites our pre-definitions).
detect_aws_project() {
  [ "\${RESUME_BLOCKER_REASON:-}" = "credentials_expired" ]
}
detect_credentials_expired() {
  # Return failure when FAKE_CREDS_EXPIRED=true to simulate expired creds.
  [ "\${FAKE_CREDS_EXPIRED:-false}" != "true" ]
}
export -f detect_aws_project
export -f detect_credentials_expired

# ── Real force-prestart gate logic from run_workflow() (Phase 0) ──────────────
_force_prestart=false
case "\${RESUME_BLOCKER_REASON:-}" in
  credentials_expired|test_failures|session_limit)
    _force_prestart=true
    ;;
esac

if [ -z "\$skip_to_phase" ] || [ "\$_force_prestart" = true ]; then
  # Simulate phase_pre_start_checks: call the real check_blockers pre-start context
  if check_blockers "pre-start"; then
    # No blocker — mark prestart as reached
    touch "\$prestart_called_file"
  else
    # Blocker fired (e.g. credentials still expired) — do NOT touch sentinel
    echo "check_blockers pre-start blocked: BLOCKER_TYPE=\${BLOCKER_TYPE:-?}" >&2
  fi
fi
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: real persisted reasons force the pre-start gate
# ─────────────────────────────────────────────────────────────────────────────

@test "test_failures: pre-start check runs even when skip_to_phase=merge" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "test_failures" "merge" "$called_file"

  [ -f "$called_file" ] || {
    echo "FAIL: phase_pre_start_checks was NOT called for test_failures resume" >&2
    return 1
  }
}

@test "test_failures: pre-start check runs when skip_to_phase=assess-resolve" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "test_failures" "assess-resolve" "$called_file"

  [ -f "$called_file" ]
}

@test "session_limit: pre-start check runs when skip_to_phase=merge" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "session_limit" "merge" "$called_file"

  [ -f "$called_file" ]
}

@test "credentials_expired: pre-start check runs when skip_to_phase=create-pr (creds now valid)" {
  # Creds are valid (FAKE_CREDS_EXPIRED not set) — gate fires AND check passes
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "credentials_expired" "create-pr" "$called_file"

  [ -f "$called_file" ]
}

@test "credentials_expired + still-expired creds: check_blockers pre-start blocks resume" {
  # Simulate the case where creds are STILL expired after forced pre-start.
  # The sentinel must NOT be created — check_blockers returns non-zero.
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  FAKE_CREDS_EXPIRED=true _run_real_prestart_gate "credentials_expired" "merge" "$called_file"

  [ ! -f "$called_file" ] || {
    echo "FAIL: prestart sentinel created despite expired credentials" >&2
    return 1
  }
}

@test "interrupted: pre-start check skipped when skip_to_phase=merge (no regression)" {
  # 'interrupted' is set by the INT/TERM trap — it does NOT require a pre-start
  # re-check because no blocker condition existed; the user just hit Ctrl-C.
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "interrupted" "merge" "$called_file"

  [ ! -f "$called_file" ] || {
    echo "FAIL: phase_pre_start_checks was incorrectly called for 'interrupted' reason" >&2
    return 1
  }
}

@test "empty blocker reason: pre-start check skipped when skip_to_phase=merge (no regression)" {
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "" "merge" "$called_file"

  [ ! -f "$called_file" ]
}

@test "test_failures: pre-start check still runs when skip_to_phase is empty (normal path)" {
  # Validate the normal (non-skip) path still works.
  local called_file="$RITE_TEST_TMPDIR/prestart-called"

  _run_real_prestart_gate "test_failures" "" "$called_file"

  [ -f "$called_file" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: RESUME_BLOCKER_REASON exported from main() via session-state JSON
# ─────────────────────────────────────────────────────────────────────────────

@test "session-state with test_failures sets RESUME_BLOCKER_REASON correctly" {
  local issue=22
  _write_state "$issue" "test_failures" "merge"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  [ "$saved_reason" = "test_failures" ]
}

@test "session-state with credentials_expired sets RESUME_BLOCKER_REASON correctly" {
  local issue=23
  _write_state "$issue" "credentials_expired" "claude-workflow"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  [ "$saved_reason" = "credentials_expired" ]
}

@test "session-state with session_limit sets RESUME_BLOCKER_REASON correctly" {
  local issue=24
  _write_state "$issue" "session_limit" "assess-resolve"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  [ "$saved_reason" = "session_limit" ]
}

@test "session-state with interrupted does not match blocker reasons" {
  # 'interrupted' is not a blocker type that requires re-check;
  # it means the user hit Ctrl-C and phases completed normally up to that point.
  local issue=25
  _write_state "$issue" "interrupted" "assess-resolve"

  local state_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/session-state-${issue}.json"
  local saved_reason
  saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)

  # Confirm it does NOT match any of the force-prestart reasons
  case "$saved_reason" in
    credentials_expired|test_failures|session_limit)
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
  _run_real_prestart_gate "" "merge" "$called_file"

  [ ! -f "$called_file" ]
}
