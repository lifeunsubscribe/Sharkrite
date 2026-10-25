#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/workflow-runner.sh::phase_completion, lib/utils/session-tracker.sh::init_session
#
# Each finished batch issue prints one Duration line carrying both clocks —
# this issue, and the batch so far — measured from the orchestrator's own
# BATCH_START_TIME, which nothing outside the batch process can move.
#
# Before: two unlabeled "Duration" lines per issue — the per-issue one, and a
# mid-batch "Session Summary" read from the session state file. When a gated
# test deleted that file (batch 1338, 2026-10-24), the "overall" figure went
# 10m 24s → 3s → 6m 9s across three issues.

setup() {
  RITE_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BATCH_SCRIPT="$RITE_REPO_ROOT/lib/core/batch-process-issues.sh"
  WORKFLOW_RUNNER="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  print_info() { echo "INFO: $*"; }
  eval "$(sed -n '/^_format_elapsed()/,/^}/p' "$RITE_REPO_ROOT/lib/utils/logging.sh")"
  eval "$(sed -n '/^_print_issue_duration()/,/^}/p' "$BATCH_SCRIPT")"
}

@test "duration line shows this issue, batch so far, and position" {
  ISSUE_DURATION=363
  BATCH_START_TIME=$(( $(date +%s) - 1970 ))
  CURRENT_ISSUE=4
  TOTAL_ISSUES=8
  run _print_issue_duration
  [ "$status" -eq 0 ]
  [[ "$output" == "INFO: Duration: 6m 3s this issue · 32m 5"*"s batch so far (4/8)" ]]
}

@test "batch clock comes from BATCH_START_TIME, not the session state file" {
  ISSUE_DURATION=10
  BATCH_START_TIME=$(( $(date +%s) - 3700 ))
  CURRENT_ISSUE=2
  TOTAL_ISSUES=3
  SESSION_STATE_FILE=/nonexistent/session.json
  run _print_issue_duration
  [[ "$output" == *"10s this issue · 1h 1m "*"s batch so far (2/3)" ]]
}

@test "every per-issue Duration print in the batch loop uses the helper" {
  run grep -c 'print_info "Duration: $(_format_elapsed "$ISSUE_DURATION")"' "$BATCH_SCRIPT"
  [ "$output" = "0" ]
  [ "$(grep -cE '^[[:space:]]+_print_issue_duration$' "$BATCH_SCRIPT")" -ge 11 ]
}

@test "phase_completion prints the session summary only outside a batch" {
  local body
  body=$(awk '/^phase_completion[(][)]/,/^}/' "$WORKFLOW_RUNNER")
  [ -n "$body" ]
  printf '%s\n' "$body" | grep -A1 'if \[ "${BATCH_MODE:-false}" != "true" \]; then' \
    | grep -q 'get_session_summary'
  # and it is not called unconditionally anywhere else in the function
  [ "$(printf '%s\n' "$body" | grep -c 'get_session_summary')" -eq 1 ]
}

@test "a lazily re-created session file keeps the run's real mode" {
  local d
  d=$(mktemp -d)
  run env -i HOME="$HOME" PATH="$PATH" SESSION_STATE_FILE="$d/s.json" \
    WORKFLOW_MODE=unsupervised RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    bash -c '
      source "$RITE_LIB_DIR/utils/session-tracker.sh" >/dev/null 2>&1 || true
      init_session
      jq -r .mode "$SESSION_STATE_FILE"'
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "unsupervised" ]
}
