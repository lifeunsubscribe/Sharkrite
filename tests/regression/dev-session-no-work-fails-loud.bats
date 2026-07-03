#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Test suite for issue #68: Add auto-commit or fail-loud guard before PR phase
#
# Verifies that when Claude dev session ends with no work done (no commits beyond
# init, no uncommitted changes), the guard fails loud with actionable remediation.

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/logging.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Create a mock git repository
  export TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO" || exit 1

  # Initialize git repo with origin/main
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create initial commit on main
  echo "# Test Repo" > README.md
  git add README.md
  git commit -m "Initial commit" --quiet

  # Simulate origin/main
  git branch -M main
  git remote add origin "file://${TEST_REPO}/.git"
  git fetch origin --quiet
  git branch --set-upstream-to=origin/main main

  # Create feature branch with init commit
  git checkout -b "feat/test-issue-42" --quiet
  git commit --allow-empty -m "chore: initialize work on #42 Test Issue" --quiet

  # Mock environment variables
  export ISSUE_NUMBER=42
  export AUTO_MODE=true
  export RITE_ORCHESTRATED=false

  # Source the function we're testing.
  # RITE_SOURCE_FUNCTIONS_ONLY=1 loads only function definitions without executing
  # the main program body (arg parsing, worktree navigation, Claude dev session).
  # Without this, sourcing launches a real Claude Code session — causing spurious
  # claude_dev_session markers in the Phase 3 test-gate log (issue #469).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_LIB_DIR}/core/claude-workflow.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
}

@test "check_dev_session_output: fails when only init commit exists and no changes" {
  # No files written - clean worktree, only init commit

  # Run the guard
  run check_dev_session_output

  # Should fail (exit 1 in standalone mode)
  [ "$status" -eq 1 ]

  # Output should explain what happened
  [[ "$output" =~ "session ended without making any changes" ]]
}

@test "check_dev_session_output: provides remediation steps on fail" {
  # No work done

  # Run the guard
  run check_dev_session_output

  # Should fail
  [ "$status" -eq 1 ]

  # Should provide actionable remediation
  [[ "$output" =~ "Possible causes:" ]]
  [[ "$output" =~ "Remediation:" ]]
  [[ "$output" =~ "rite ${ISSUE_NUMBER} --undo" ]] || [[ "$output" =~ "rite 42 --undo" ]]
}

@test "check_dev_session_output: exit code 4 in orchestrated mode when no work" {
  # Enable orchestrated mode
  export RITE_ORCHESTRATED=true

  # No work done

  # Run the guard
  run check_dev_session_output

  # Should exit 4 (for orchestrator retry logic)
  [ "$status" -eq 4 ]
}

@test "check_dev_session_output: logs diagnostic on fail-loud" {
  # Create log file
  export RITE_LOG_FILE=$(mktemp)

  # No work done

  # Run the guard
  run check_dev_session_output

  # Should fail
  [ "$status" -eq 1 ]

  # Diagnostic log should contain NO_WORK entry
  grep -q "\[diag\].*NO_WORK" "$RITE_LOG_FILE"
  grep -q "issue=42" "$RITE_LOG_FILE"
  grep -q "commits=" "$RITE_LOG_FILE"
  grep -q "uncommitted=0" "$RITE_LOG_FILE"

  # Clean up
  rm -f "$RITE_LOG_FILE"
}

@test "check_dev_session_output: fails when no commits beyond init (0 commits ahead)" {
  # Delete the init commit to simulate 0 commits ahead of origin/main
  git reset --hard origin/main --quiet

  # Run the guard
  run check_dev_session_output

  # Should fail
  [ "$status" -eq 1 ]

  # Should mention no changes
  [[ "$output" =~ "without making any changes" ]]
}

@test "check_dev_session_output: succeeds when non-init commit exists" {
  # Simulate Claude making a real commit (not init commit)
  echo "const VERSION = '1.0.0';" > version.js
  git add version.js
  git commit -m "feat: add version" --quiet

  # Run the guard
  run check_dev_session_output

  # Should succeed (silent success)
  [ "$status" -eq 0 ]

  # Should have no output (no action needed)
  [ -z "$output" ]
}

@test "check_dev_session_output: handles missing origin/main gracefully" {
  # Remove origin remote (simulates new repo without remote)
  git remote remove origin

  # No work done

  # Run the guard - should still detect no work and fail
  run check_dev_session_output

  # Should fail (even without origin/main, we can detect no commits)
  [ "$status" -eq 1 ]

  # Should still provide useful error message
  [[ "$output" =~ "without making any changes" ]]
}

@test "check_dev_session_output: mentions possible causes in error" {
  # No work done

  # Run the guard
  run check_dev_session_output

  # Should fail
  [ "$status" -eq 1 ]

  # Should mention possible causes
  [[ "$output" =~ "judged the issue not actionable" ]]
  [[ "$output" =~ "session crashed mid-edit" ]]
  [[ "$output" =~ "Hard misread" ]]
}
