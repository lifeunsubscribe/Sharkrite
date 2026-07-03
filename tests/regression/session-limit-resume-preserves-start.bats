#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh
# Regression test for issue #283: RITE_RESUMING=true preserves start_time
#
# Verifies that when init_session is called with RITE_RESUMING=true, the
# existing state file (including start_time and cumulative_work_seconds) is
# preserved unchanged. This is the explicit resume path used by crash-recovery
# and supervised reload workflows.
#
# Contrast with session-limit-zombie-file.bats which tests the fresh-invocation
# (RITE_RESUMING=false) path that SHOULD reset start_time.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_TEST_TMPDIR="$(mktemp -d)"

  export RITE_PROJECT_NAME="test-resume-$$"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"

  export SESSION_STATE_FILE="${RITE_TEST_TMPDIR}/rite-session-state-${RITE_PROJECT_NAME}.json"

  source "${RITE_LIB_DIR}/utils/session-tracker.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  rm -rf "$RITE_TEST_TMPDIR"
}

# Helper: write a state file simulating a mid-run resume snapshot
_write_resume_state() {
  local known_start="$1"
  local known_cumulative="${2:-7200}"  # default 2h
  local known_issue="${3:-99}"

  cat > "$SESSION_STATE_FILE" <<EOF
{
  "start_time": ${known_start},
  "mode": "supervised",
  "issues_completed": 2,
  "issues_failed": 0,
  "current_issue": "${known_issue}",
  "worktree_path": "/tmp/resume-worktree",
  "current_issue_started_at": null,
  "cumulative_work_seconds": ${known_cumulative},
  "approved_blockers": ["42:critical_issues"],
  "sent_notifications": [],
  "last_update": ${known_start}
}
EOF
}

@test "RITE_RESUMING=true: start_time is preserved from existing file" {
  local known_start=$(( $(date +%s) - 3600 ))  # 1h ago
  _write_resume_state "$known_start"

  RITE_RESUMING=true init_session "supervised"

  local read_start
  read_start=$(jq -r '.start_time' "$SESSION_STATE_FILE")
  [ "$read_start" -eq "$known_start" ]
}

@test "RITE_RESUMING=true: cumulative_work_seconds is preserved" {
  local known_start=$(( $(date +%s) - 3600 ))
  _write_resume_state "$known_start" "14400"  # 4h

  RITE_RESUMING=true init_session "supervised"

  local cumul
  cumul=$(jq -r '.cumulative_work_seconds' "$SESSION_STATE_FILE")
  [ "$cumul" -eq 14400 ]
}

@test "RITE_RESUMING=true: current_issue is preserved" {
  local known_start=$(( $(date +%s) - 3600 ))
  _write_resume_state "$known_start" "7200" "99"

  RITE_RESUMING=true init_session "supervised"

  local issue
  issue=$(jq -r '.current_issue' "$SESSION_STATE_FILE")
  [ "$issue" = "99" ]
}

@test "RITE_RESUMING=true: approved_blockers are preserved" {
  local known_start=$(( $(date +%s) - 3600 ))
  _write_resume_state "$known_start"

  RITE_RESUMING=true init_session "supervised"

  local blocker_count
  blocker_count=$(jq -r '.approved_blockers | length' "$SESSION_STATE_FILE")
  [ "$blocker_count" -eq 1 ]

  local blocker
  blocker=$(jq -r '.approved_blockers[0]' "$SESSION_STATE_FILE")
  [ "$blocker" = "42:critical_issues" ]
}

@test "RITE_RESUMING=true: issues_completed count is preserved" {
  local known_start=$(( $(date +%s) - 3600 ))
  _write_resume_state "$known_start"

  RITE_RESUMING=true init_session "supervised"

  local completed
  completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE")
  [ "$completed" -eq 2 ]
}

@test "RITE_RESUMING=false: contrasting test — start_time IS reset on fresh call" {
  local old_start=$(( $(date +%s) - 144000 ))  # 40h ago
  _write_resume_state "$old_start"

  local before
  before=$(date +%s)

  RITE_RESUMING=false init_session "supervised"

  local new_start
  new_start=$(jq -r '.start_time' "$SESSION_STATE_FILE")
  [ "$new_start" -ge "$before" ]
}

@test "RITE_RESUMING=true with no state file: creates fresh state (no error)" {
  # If RITE_RESUMING=true but no file exists, fall through to fresh init
  [ ! -f "$SESSION_STATE_FILE" ]

  RITE_RESUMING=true init_session "supervised"

  [ -f "$SESSION_STATE_FILE" ]

  local mode
  mode=$(jq -r '.mode' "$SESSION_STATE_FILE")
  [ "$mode" = "supervised" ]
}

@test "SESSION_START_TIME export: RITE_RESUMING=true exports the preserved start_time" {
  local known_start=$(( $(date +%s) - 1800 ))  # 30min ago
  _write_resume_state "$known_start"

  RITE_RESUMING=true init_session "supervised"

  [ -n "${SESSION_START_TIME:-}" ]
  [ "$SESSION_START_TIME" -eq "$known_start" ]
}
