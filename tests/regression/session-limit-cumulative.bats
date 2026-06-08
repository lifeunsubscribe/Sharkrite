#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh
# Regression test for issue #283: Cumulative active-work session cap
#
# Verifies that detect_session_limit reads cumulative_work_seconds (not
# wall-clock since start_time) and fires when total active work exceeds
# RITE_MAX_SESSION_HOURS (default: 12h).
#
# Simulates multiple issues completing and the cumulative counter crossing
# the threshold.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_TEST_TMPDIR="$(mktemp -d)"

  export RITE_PROJECT_NAME="test-cumulative-$$"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"

  export SESSION_STATE_FILE="${RITE_TEST_TMPDIR}/rite-session-state-${RITE_PROJECT_NAME}.json"

  # Pin session limits explicitly so tests are deterministic regardless of what
  # the parent environment or .rite/config sets (issue #283).
  export RITE_MAX_SESSION_HOURS=12
  export RITE_MAX_ISSUES_PER_SESSION=8

  source "${RITE_LIB_DIR}/utils/session-tracker.sh"
  source "${RITE_LIB_DIR}/utils/blocker-rules.sh"

  RITE_RESUMING=false init_session "supervised"
}

teardown() {
  rm -rf "$RITE_TEST_TMPDIR"
}

# Helper: manually set cumulative_work_seconds in state file
_set_cumulative() {
  local secs="$1"
  local _tmp
  _tmp=$(mktemp)
  jq --argjson s "$secs" '.cumulative_work_seconds = $s' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"
}

@test "detect_session_limit: does NOT fire at 0 cumulative hours" {
  run detect_session_limit "0" "0"
  [ "$status" -eq 0 ]
}

@test "detect_session_limit: does NOT fire at 11 cumulative hours (below default 12h)" {
  run detect_session_limit "0" "11"
  [ "$status" -eq 0 ]
}

@test "detect_session_limit: fires at RITE_MAX_SESSION_HOURS (default 12h)" {
  run detect_session_limit "0" "12"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cumulative active work limit reached"* ]]
}

@test "detect_session_limit: fires above default 12h threshold" {
  run detect_session_limit "0" "15"
  [ "$status" -eq 1 ]
}

@test "detect_session_limit: old 4h default no longer triggers at 4h" {
  # After fix, 4h of cumulative work should NOT fire the session_limit
  # (default raised to 12h). This catches regression if default reverts.
  run detect_session_limit "0" "4"
  [ "$status" -eq 0 ]
}

@test "detect_session_limit: respects RITE_MAX_SESSION_HOURS override" {
  RITE_MAX_SESSION_HOURS=2 run detect_session_limit "0" "2"
  [ "$status" -eq 1 ]
}

@test "detect_session_limit: fires on issue count cap regardless of hours" {
  run detect_session_limit "8" "0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"token limit"* ]] || [[ "$output" == *"Approaching token limit"* ]]
}

@test "get_cumulative_work_seconds: returns 0 for fresh session" {
  run get_cumulative_work_seconds
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "get_cumulative_work_seconds: returns persisted value" {
  _set_cumulative 7200  # 2 hours

  run get_cumulative_work_seconds
  [ "$status" -eq 0 ]
  [ "$output" -eq 7200 ]
}

@test "get_cumulative_work_seconds: includes in-progress issue time" {
  # Pre-load 1 hour of prior work
  _set_cumulative 3600

  # Start an issue 60 seconds ago
  local sixty_ago=$(( $(date +%s) - 60 ))
  local _tmp
  _tmp=$(mktemp)
  jq --argjson t "$sixty_ago" '.current_issue_started_at = $t' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"

  run get_cumulative_work_seconds
  [ "$status" -eq 0 ]
  # Should be 3600 + ~60 seconds
  [ "$output" -ge 3650 ]
  [ "$output" -le 3680 ]
}

@test "cumulative cap: simulate 3 issues crossing 12h total" {
  # Simulate: issue 1 = 4h, issue 2 = 4h, issue 3 = 4h = 12h total

  # After issue 1
  _set_cumulative $(( 4 * 3600 ))
  local h1=$(( $(get_cumulative_work_seconds) / 3600 ))
  run detect_session_limit "1" "$h1"
  [ "$status" -eq 0 ]  # 4h — no cap

  # After issue 2
  _set_cumulative $(( 8 * 3600 ))
  local h2=$(( $(get_cumulative_work_seconds) / 3600 ))
  run detect_session_limit "2" "$h2"
  [ "$status" -eq 0 ]  # 8h — no cap

  # After issue 3 (12h cumulative)
  _set_cumulative $(( 12 * 3600 ))
  local h3=$(( $(get_cumulative_work_seconds) / 3600 ))
  run detect_session_limit "3" "$h3"
  [ "$status" -eq 1 ]  # 12h — cap fires
  [[ "$output" == *"Cumulative active work limit reached"* ]]
}

@test "end_issue_tracking: multiple issues accumulate correctly" {
  # Issue 1: 2h
  local start1=$(( $(date +%s) - 7200 ))
  local _tmp
  _tmp=$(mktemp)
  jq --argjson t "$start1" \
     '.current_issue_started_at = $t | .cumulative_work_seconds = 0' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"
  end_issue_tracking "1"

  # Issue 2: 3h
  local start2=$(( $(date +%s) - 10800 ))
  _tmp=$(mktemp)
  jq --argjson t "$start2" '.current_issue_started_at = $t' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"
  end_issue_tracking "2"

  local total
  total=$(get_cumulative_work_seconds)
  # Should be ~5h = 18000s; allow 30s window for test execution
  [ "$total" -ge 17970 ]
  [ "$total" -le 18030 ]
}
