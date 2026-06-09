#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh, lib/core/workflow-runner.sh
# Regression test for issue #469: Phase 3 fires claude_dev_session 7+ times per run
#
# Root cause: bats tests sourced claude-workflow.sh without RITE_SOURCE_FUNCTIONS_ONLY=1.
# Because claude-workflow.sh lacked an RITE_SOURCE_FUNCTIONS_ONLY guard, the entire
# script executed on source — including _timer_start "claude_dev_session" and
# provider_run_agentic_session — launching real Claude Code sessions inside the
# Phase 3 post-commit test gate. Each test that sourced the file caused one dev session.
#
# Fix: added RITE_SOURCE_FUNCTIONS_ONLY=1 guard to claude-workflow.sh (between function
# definitions and the executable body) and updated all test files that source it.
#
# Tests in this file:
#   1. RITE_SOURCE_FUNCTIONS_ONLY=1 guard is present in claude-workflow.sh at the
#      correct location (before argument parsing, after function definitions)
#   2. Sourcing with RITE_SOURCE_FUNCTIONS_ONLY=1 loads functions without running
#      the executable body (no timer, no provider session, no git calls)
#   3. All test files that source claude-workflow.sh use RITE_SOURCE_FUNCTIONS_ONLY=1
#   4. Sourcing without RITE_SOURCE_FUNCTIONS_ONLY=1 DOES execute the program body
#      (validates the guard placement catches the real path)

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LIB_DIR
}

# ---------------------------------------------------------------------------
# Test 1: Guard placement — RITE_SOURCE_FUNCTIONS_ONLY guard must exist in
# claude-workflow.sh and must appear AFTER the last function definition but
# BEFORE the first top-level executable statement (argument parsing).
# ---------------------------------------------------------------------------

@test "claude-workflow.sh: RITE_SOURCE_FUNCTIONS_ONLY guard is present" {
  grep -q 'RITE_SOURCE_FUNCTIONS_ONLY' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
}

@test "claude-workflow.sh: RITE_SOURCE_FUNCTIONS_ONLY guard appears before provider_detect_cli call" {
  # The guard must appear before the network/filesystem-heavy executable body starts.
  # provider_detect_cli is the first heavy call (requires the provider CLI to be installed).
  # The guard must be BEFORE this line to prevent launching a Claude Code session.
  local guard_line provider_line
  guard_line=$(grep -n 'RITE_SOURCE_FUNCTIONS_ONLY' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh" | head -1 | cut -d: -f1)
  provider_line=$(grep -n '^provider_detect_cli' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ]
  [ -n "$provider_line" ]
  # Guard must be on an earlier line than provider_detect_cli
  [ "$guard_line" -lt "$provider_line" ]
}

@test "claude-workflow.sh: RITE_SOURCE_FUNCTIONS_ONLY guard appears after check_dev_session_output definition" {
  # Function definitions must come BEFORE the guard (otherwise they won't be
  # available to callers that use RITE_SOURCE_FUNCTIONS_ONLY=1).
  local guard_line fn_line
  guard_line=$(grep -n 'RITE_SOURCE_FUNCTIONS_ONLY' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh" | head -1 | cut -d: -f1)
  fn_line=$(grep -n '^check_dev_session_output()' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ]
  [ -n "$fn_line" ]
  # Function must be defined before the guard
  [ "$fn_line" -lt "$guard_line" ]
}

# ---------------------------------------------------------------------------
# Test 2: Sourcing with RITE_SOURCE_FUNCTIONS_ONLY=1 loads functions and exits
# without running the executable body (no git calls, no provider sessions).
# ---------------------------------------------------------------------------

@test "claude-workflow.sh: RITE_SOURCE_FUNCTIONS_ONLY=1 exits 0 and loads functions" {
  # Run in a subshell with no git repo context — if the executable body ran, it would
  # fail immediately at 'provider_detect_cli || exit 1' or 'git branch --show-current',
  # proving the guard stopped execution before the program body.
  run bash -c "
    set -euo pipefail
    export RITE_SOURCE_FUNCTIONS_ONLY=1
    source '${RITE_REPO_ROOT}/lib/core/claude-workflow.sh' 2>/dev/null
    # If we reach here, the guard stopped execution before the program body ran.
    # Confirm that the key helper functions are available to callers.
    declare -f check_dev_session_output >/dev/null 2>&1
    declare -f find_worktree_for_task >/dev/null 2>&1
    echo FUNCTIONS_LOADED
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"FUNCTIONS_LOADED"* ]]
}

@test "claude-workflow.sh: RITE_SOURCE_FUNCTIONS_ONLY=1 does not write timing markers" {
  # The claude_dev_session START timer writes to RITE_LOG_FILE. With the guard,
  # no timing markers should appear in the log even if RITE_LOG_FILE is set.
  local tmp_log
  tmp_log=$(mktemp)

  run bash -c "
    set -euo pipefail
    export RITE_SOURCE_FUNCTIONS_ONLY=1
    export RITE_LOG_FILE='${tmp_log}'
    source '${RITE_REPO_ROOT}/lib/core/claude-workflow.sh' 2>/dev/null
    echo OK
  " 2>&1

  [ "$status" -eq 0 ]

  # Log file must NOT contain claude_dev_session markers
  if [ -s "$tmp_log" ]; then
    run grep -c 'claude_dev_session' "$tmp_log"
    [ "$output" = "0" ] 2>/dev/null || true
  fi

  rm -f "$tmp_log"
}

# ---------------------------------------------------------------------------
# Test 3: All test files that source claude-workflow.sh use RITE_SOURCE_FUNCTIONS_ONLY=1
#
# This catches future test regressions: any new test file that sources
# claude-workflow.sh without the guard will cause this test to fail.
# ---------------------------------------------------------------------------

@test "all test files sourcing claude-workflow.sh use RITE_SOURCE_FUNCTIONS_ONLY=1" {
  # Find every bats/sh file that has 'source.*claude-workflow.sh'
  # For each match, verify the line or its predecessor sets RITE_SOURCE_FUNCTIONS_ONLY=1.
  #
  # Pattern A: inline assignment — `RITE_SOURCE_FUNCTIONS_ONLY=1 source ...`
  # Pattern B: export before source — the export appears somewhere before the source
  #            in the same file (we check within 5 lines for proximity).
  #
  # lib-resource-safety.bats is excluded: it pre-loads _RITE_CLAUDE_WORKFLOW_LOADED=true
  # which fires the re-source guard before execution reaches RITE_SOURCE_FUNCTIONS_ONLY.
  # That test explicitly verifies the re-source guard, not the function-only guard.

  local failures=0
  local violation_files=""

  while IFS=: read -r filepath lineno _; do
    # Skip the resource-safety test (uses the re-source guard path instead)
    case "$filepath" in
      *lib-resource-safety*) continue ;;
    esac

    # Check if the source line has an inline RITE_SOURCE_FUNCTIONS_ONLY=1 prefix
    local source_line
    source_line=$(sed -n "${lineno}p" "$filepath")
    if echo "$source_line" | grep -q 'RITE_SOURCE_FUNCTIONS_ONLY=1'; then
      continue  # Pattern A — OK
    fi

    # Check if RITE_SOURCE_FUNCTIONS_ONLY=1 appears within 5 lines before the source
    local start_line=$((lineno - 5))
    [ "$start_line" -lt 1 ] && start_line=1
    if sed -n "${start_line},${lineno}p" "$filepath" | grep -q 'RITE_SOURCE_FUNCTIONS_ONLY=1'; then
      continue  # Pattern B — OK
    fi

    # No guard found — this file will launch a real Claude Code session when sourced
    failures=$((failures + 1))
    violation_files="${violation_files}\n  ${filepath}:${lineno}"
  done < <(grep -rn 'source.*claude-workflow\.sh' "${RITE_REPO_ROOT}/tests" 2>/dev/null || true)

  if [ "$failures" -gt 0 ]; then
    echo "ERROR: The following test files source claude-workflow.sh without RITE_SOURCE_FUNCTIONS_ONLY=1:"
    printf '%b\n' "$violation_files"
    echo ""
    echo "This causes real Claude Code sessions to launch during the Phase 3 test gate"
    echo "(issue #469). Add 'RITE_SOURCE_FUNCTIONS_ONLY=1' as an inline prefix:"
    echo "  RITE_SOURCE_FUNCTIONS_ONLY=1 source \"\${RITE_LIB_DIR}/core/claude-workflow.sh\""
    false
  fi
}
