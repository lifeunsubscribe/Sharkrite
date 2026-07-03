#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh
# Regression test for issue #283: Session-limit blocker measures file age, not work
#
# Verifies that a stale "zombie" state file from a prior invocation does NOT
# cause init_session() to inherit the old start_time, which would trigger the
# session_limit blocker on a fresh invocation.
#
# Reproduces the live failure: rm /tmp/rite-session-state-sharkrite.json was
# the only workaround before this fix.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_TEST_TMPDIR="$(mktemp -d)"

  # Minimal project env so config.sh + session-tracker.sh can load
  export RITE_PROJECT_NAME="test-zombie-$$"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"

  # Point SESSION_STATE_FILE at our temp dir (not /tmp, to avoid polluting real state)
  export SESSION_STATE_FILE="${RITE_TEST_TMPDIR}/rite-session-state-${RITE_PROJECT_NAME}.json"

  # Source only what session-tracker.sh needs directly (avoid full config.sh chain)
  source "${RITE_LIB_DIR}/utils/session-tracker.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  rm -rf "$RITE_TEST_TMPDIR"
}

# Helper: write a zombie state file with a start_time 40 hours in the past
_write_zombie_file() {
  local stale_epoch=$(( $(date +%s) - 144000 ))  # 40 hours ago
  cat > "$SESSION_STATE_FILE" <<EOF
{
  "start_time": ${stale_epoch},
  "mode": "batch-60-1780293116",
  "issues_completed": 5,
  "issues_failed": 0,
  "current_issue": "35",
  "worktree_path": "/tmp/old-worktree",
  "current_issue_started_at": null,
  "cumulative_work_seconds": 14400,
  "approved_blockers": ["99:critical_issues"],
  "sent_notifications": ["42:blocker:credentials_expired"],
  "last_update": ${stale_epoch}
}
EOF
}

@test "init_session: fresh invocation with zombie file resets start_time to now" {
  _write_zombie_file

  local before
  before=$(date +%s)

  # Fresh invocation (no RITE_RESUMING=true)
  RITE_RESUMING=false init_session "supervised"

  local after
  after=$(date +%s)

  # Read the new start_time
  local new_start
  new_start=$(jq -r '.start_time' "$SESSION_STATE_FILE")

  # start_time must be >= before and <= after (i.e., set to approximately now)
  [ "$new_start" -ge "$before" ]
  [ "$new_start" -le "$after" ]
}

@test "init_session: zombie file reset preserves approved_blockers" {
  _write_zombie_file

  RITE_RESUMING=false init_session "supervised"

  local preserved
  preserved=$(jq -r '.approved_blockers | length' "$SESSION_STATE_FILE")
  [ "$preserved" -eq 1 ]

  local blocker
  blocker=$(jq -r '.approved_blockers[0]' "$SESSION_STATE_FILE")
  [ "$blocker" = "99:critical_issues" ]
}

@test "init_session: zombie file reset preserves sent_notifications" {
  _write_zombie_file

  RITE_RESUMING=false init_session "supervised"

  local preserved
  preserved=$(jq -r '.sent_notifications | length' "$SESSION_STATE_FILE")
  [ "$preserved" -eq 1 ]

  local notif
  notif=$(jq -r '.sent_notifications[0]' "$SESSION_STATE_FILE")
  [ "$notif" = "42:blocker:credentials_expired" ]
}

@test "init_session: zombie file reset clears current_issue" {
  _write_zombie_file

  RITE_RESUMING=false init_session "supervised"

  local current
  current=$(jq -r '.current_issue' "$SESSION_STATE_FILE")
  [ "$current" = "null" ]
}

@test "init_session: zombie file reset clears worktree_path" {
  _write_zombie_file

  RITE_RESUMING=false init_session "supervised"

  local wt
  wt=$(jq -r '.worktree_path' "$SESSION_STATE_FILE")
  [ "$wt" = "null" ]
}

@test "init_session: zombie file reset sets cumulative_work_seconds to 0" {
  _write_zombie_file

  RITE_RESUMING=false init_session "supervised"

  local cumul
  cumul=$(jq -r '.cumulative_work_seconds' "$SESSION_STATE_FILE")
  [ "$cumul" -eq 0 ]
}

@test "get_cumulative_work_seconds: returns 0 after zombie file reset" {
  _write_zombie_file

  # After fresh init, cumulative is reset to 0
  RITE_RESUMING=false init_session "supervised"

  run get_cumulative_work_seconds
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "zombie scenario end-to-end: stale file + fresh init = 0 cumulative work hours" {
  _write_zombie_file

  # Simulate what workflow-runner.sh does: fresh init (no RITE_RESUMING)
  RITE_RESUMING=false init_session "supervised"

  # Cumulative work after reset = 0 seconds → 0 hours
  local cumulative_secs
  cumulative_secs=$(get_cumulative_work_seconds)
  local cumulative_hours=$(( cumulative_secs / 3600 ))

  # cumulative_hours must be 0 — the zombie's 40h of file-age contributes nothing
  [ "$cumulative_hours" -eq 0 ]
}
