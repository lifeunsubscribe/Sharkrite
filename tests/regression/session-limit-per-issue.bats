#!/usr/bin/env bats
# Regression test for issue #283: Per-issue duration cap
#
# Verifies that detect_issue_duration_limit fires when a single issue has been
# running longer than RITE_MAX_ISSUE_HOURS (default: 4h).
#
# Also verifies start_issue_tracking / end_issue_tracking accumulate correctly.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_TEST_TMPDIR="$(mktemp -d)"

  export RITE_PROJECT_NAME="test-per-issue-$$"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"

  export SESSION_STATE_FILE="${RITE_TEST_TMPDIR}/rite-session-state-${RITE_PROJECT_NAME}.json"

  # Pin RITE_MAX_ISSUE_HOURS explicitly so tests don't depend on env/config
  export RITE_MAX_ISSUE_HOURS=4

  source "${RITE_LIB_DIR}/utils/session-tracker.sh"
  source "${RITE_LIB_DIR}/utils/blocker-rules.sh"

  # Initialize a fresh session
  RITE_RESUMING=false init_session "supervised"
}

teardown() {
  rm -rf "$RITE_TEST_TMPDIR"
}

# Helper: write current_issue_started_at to a time N hours ago
_backdate_issue_start() {
  local hours_ago="$1"
  local stale_epoch=$(( $(date +%s) - hours_ago * 3600 ))
  local _tmp
  _tmp=$(mktemp)
  jq --argjson t "$stale_epoch" '.current_issue_started_at = $t' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"
}

@test "detect_issue_duration_limit: does NOT fire at 0 hours elapsed" {
  run detect_issue_duration_limit "42" "0"
  [ "$status" -eq 0 ]
}

@test "detect_issue_duration_limit: does NOT fire at 3 hours elapsed (below default 4h)" {
  run detect_issue_duration_limit "42" "3"
  [ "$status" -eq 0 ]
}

@test "detect_issue_duration_limit: fires at RITE_MAX_ISSUE_HOURS (default 4h)" {
  run detect_issue_duration_limit "42" "4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Issue #42 has been running"* ]]
}

@test "detect_issue_duration_limit: fires above default threshold" {
  run detect_issue_duration_limit "42" "5"
  [ "$status" -eq 1 ]
}

@test "detect_issue_duration_limit: respects RITE_MAX_ISSUE_HOURS override" {
  RITE_MAX_ISSUE_HOURS=2 run detect_issue_duration_limit "100" "2"
  [ "$status" -eq 1 ]
}

@test "detect_issue_duration_limit: does not fire below custom RITE_MAX_ISSUE_HOURS" {
  RITE_MAX_ISSUE_HOURS=2 run detect_issue_duration_limit "100" "1"
  [ "$status" -eq 0 ]
}

@test "detect_issue_duration_limit: blocker message includes issue number" {
  run detect_issue_duration_limit "274" "5"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#274"* ]]
}

@test "start_issue_tracking: sets current_issue_started_at to approximately now" {
  local before
  before=$(date +%s)

  start_issue_tracking "42"

  local after
  after=$(date +%s)

  local started
  started=$(jq -r '.current_issue_started_at' "$SESSION_STATE_FILE")

  [ "$started" != "null" ]
  [ "$started" -ge "$before" ]
  [ "$started" -le "$after" ]
}

@test "end_issue_tracking: clears current_issue_started_at" {
  start_issue_tracking "42"
  end_issue_tracking "42"

  local started
  started=$(jq -r '.current_issue_started_at' "$SESSION_STATE_FILE")
  [ "$started" = "null" ]
}

@test "end_issue_tracking: increments cumulative_work_seconds" {
  # Backdate issue start by 30 minutes
  start_issue_tracking "42"
  _backdate_issue_start 0  # Reuse: just manually set it 30s ago for precision
  # Instead set it manually to 30s ago
  local thirty_ago=$(( $(date +%s) - 30 ))
  local _tmp
  _tmp=$(mktemp)
  jq --argjson t "$thirty_ago" '.current_issue_started_at = $t' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"

  end_issue_tracking "42"

  local cumulative
  cumulative=$(jq -r '.cumulative_work_seconds' "$SESSION_STATE_FILE")

  # Should have added ~30 seconds; allow 5s window for test execution time
  [ "$cumulative" -ge 25 ]
  [ "$cumulative" -le 60 ]
}

@test "get_current_issue_elapsed_seconds: returns 0 when no issue tracked" {
  run get_current_issue_elapsed_seconds
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "get_current_issue_elapsed_seconds: returns elapsed seconds when issue tracked" {
  local twenty_ago=$(( $(date +%s) - 20 ))
  local _tmp
  _tmp=$(mktemp)
  jq --argjson t "$twenty_ago" '.current_issue_started_at = $t' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"

  run get_current_issue_elapsed_seconds
  [ "$status" -eq 0 ]
  # Should be ~20s; allow 5s window
  [ "$output" -ge 15 ]
  [ "$output" -le 30 ]
}
