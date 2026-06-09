#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh
# Regression test for: get_session_summary mixes per-invocation Duration with
# cumulative issues_completed
#
# Bug history:
#   2026-06-08 — `rite 395` (single issue) reported:
#     Mode: unsupervised
#     Duration: 6m 50s
#     Issues Completed: 10
#     Total Processed: 10
#   The invocation actually processed exactly one issue (#395). The "10" was
#   leftover from prior `rite N` runs that touched the same
#   /tmp/rite-session-state-${PROJECT_NAME}.json file. init_session resets
#   start_time and cumulative_work_seconds on fresh invocation (intentional —
#   they're per-invocation) but had left issues_completed and issues_failed
#   untouched, so the summary mixed scopes.
#
# Contract:
#   On a fresh-invocation init_session (RITE_RESUMING != true) against an
#   existing state file, issues_completed AND issues_failed must be reset to
#   0 — matching the Duration / cumulative_work_seconds reset that's already
#   in place. Together they give get_session_summary a single coherent scope.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_TEST_TMPDIR="$(mktemp -d)"

  export RITE_PROJECT_NAME="test-summary-$$"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"

  export SESSION_STATE_FILE="${RITE_TEST_TMPDIR}/rite-session-state-${RITE_PROJECT_NAME}.json"

  source "${RITE_LIB_DIR}/utils/session-tracker.sh"
}

teardown() {
  rm -rf "$RITE_TEST_TMPDIR"
}

# Helper: simulate a state file from a prior invocation with leftover counters
_write_prior_state() {
  local prior_start="$1"
  local prior_completed="$2"
  local prior_failed="$3"

  cat > "$SESSION_STATE_FILE" <<EOF
{
  "start_time": ${prior_start},
  "mode": "unsupervised",
  "issues_completed": ${prior_completed},
  "issues_failed": ${prior_failed},
  "current_issue": null,
  "worktree_path": null,
  "current_issue_started_at": null,
  "cumulative_work_seconds": 1234,
  "approved_blockers": ["42:critical_issues"],
  "sent_notifications": ["push:#42:merged"],
  "last_update": ${prior_start}
}
EOF
}

# ---------------------------------------------------------------------------
# Test: fresh invocation resets issues_completed (the live #395 bug)
# ---------------------------------------------------------------------------
@test "fresh invocation: issues_completed is reset to 0" {
  local prior_start=$(( $(date +%s) - 86400 ))  # 1d ago
  _write_prior_state "$prior_start" 10 0

  # Fresh invocation — no RITE_RESUMING in env
  unset RITE_RESUMING
  init_session "unsupervised"

  local issues_completed
  issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE")
  [ "$issues_completed" = "0" ]
}

# ---------------------------------------------------------------------------
# Test: fresh invocation resets issues_failed too (same scope)
# ---------------------------------------------------------------------------
@test "fresh invocation: issues_failed is reset to 0" {
  local prior_start=$(( $(date +%s) - 86400 ))
  _write_prior_state "$prior_start" 5 3

  unset RITE_RESUMING
  init_session "unsupervised"

  local issues_failed
  issues_failed=$(jq -r '.issues_failed' "$SESSION_STATE_FILE")
  [ "$issues_failed" = "0" ]
}

# ---------------------------------------------------------------------------
# Test: RITE_RESUMING=true preserves counters (resume contract unchanged)
# ---------------------------------------------------------------------------
@test "RITE_RESUMING=true: issues_completed and issues_failed are preserved" {
  local prior_start=$(( $(date +%s) - 3600 ))
  _write_prior_state "$prior_start" 7 2

  RITE_RESUMING=true init_session "unsupervised"

  local issues_completed issues_failed
  issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE")
  issues_failed=$(jq -r '.issues_failed' "$SESSION_STATE_FILE")
  [ "$issues_completed" = "7" ]
  [ "$issues_failed" = "2" ]
}

# ---------------------------------------------------------------------------
# Test: durable cross-run state survives the reset
#   approved_blockers and sent_notifications are intentionally preserved
#   even on fresh invocation. The counter reset must not regress that.
# ---------------------------------------------------------------------------
@test "fresh invocation: approved_blockers and sent_notifications still preserved" {
  local prior_start=$(( $(date +%s) - 86400 ))
  _write_prior_state "$prior_start" 10 0

  unset RITE_RESUMING
  init_session "unsupervised"

  local approved sent
  approved=$(jq -r '.approved_blockers[0]' "$SESSION_STATE_FILE")
  sent=$(jq -r '.sent_notifications[0]' "$SESSION_STATE_FILE")
  [ "$approved" = "42:critical_issues" ]
  [ "$sent" = "push:#42:merged" ]
}

# ---------------------------------------------------------------------------
# Test: end-to-end summary line reflects per-invocation counts
#   Simulates the live #395 flow: prior state has 9 completed, fresh
#   invocation processes 1 issue, get_session_summary must report 1, not 10.
# ---------------------------------------------------------------------------
@test "summary after fresh invocation + one completed issue shows 1, not cumulative" {
  local prior_start=$(( $(date +%s) - 86400 ))
  _write_prior_state "$prior_start" 9 0

  unset RITE_RESUMING
  init_session "unsupervised"
  increment_completed

  run get_session_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issues Completed: 1"* ]]
  [[ "$output" == *"Total Processed: 1"* ]]
  # Belt-and-suspenders: explicitly assert the stale "10" did NOT carry over
  [[ "$output" != *"Issues Completed: 10"* ]]
}
