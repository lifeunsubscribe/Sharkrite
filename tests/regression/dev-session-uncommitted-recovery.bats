#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Test suite for issue #68: Add auto-commit or fail-loud guard before PR phase
#
# Verifies that when Claude dev session ends with uncommitted changes (files written
# but not committed), the guard auto-commits them to salvage the work.

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/logging.sh"

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

  # Simulate origin/main (worktree workflows use origin/main as base)
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
  export RITE_DATA_DIR=".rite"

  # Guard: ensure _diag writes to RITE_LOG_FILE (not stderr).
  # Without this, a caller environment with RITE_VERBOSE=true routes diag
  # output to stderr (captured by bats 'run' in $output) instead of the
  # log file, causing the "logs diagnostic on auto-commit" assertion to
  # fail even though the implementation is correct.  Pattern matches
  # conflict-resolver-diag.bats, followup-lock-timeout-diag.bats, etc.
  unset RITE_VERBOSE

  # Source the function we're testing.
  # RITE_SOURCE_FUNCTIONS_ONLY=1 loads only function definitions without executing
  # the main program body (arg parsing, worktree navigation, Claude dev session).
  # Without this, sourcing launches a real Claude Code session (issue #469).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_LIB_DIR}/core/claude-workflow.sh"
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
}

@test "check_dev_session_output: auto-commits uncommitted modified files" {
  # Simulate Claude writing files but not committing them
  echo "function foo() { return 42; }" > lib.js
  git add lib.js
  # Don't commit - this simulates Claude staging but not committing

  # Run the guard
  run check_dev_session_output

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should have created an auto-commit
  COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)
  [ "$COMMITS_AHEAD" -eq 2 ]  # init commit + auto-commit

  # Auto-commit should have the right message
  LAST_COMMIT_MSG=$(git log -1 --format=%s)
  [[ "$LAST_COMMIT_MSG" == *"auto-commit dev session output"* ]]

  # File should be committed
  git diff --quiet HEAD -- lib.js
}

@test "check_dev_session_output: auto-commits untracked files" {
  # Simulate Claude writing new files but not adding/committing them
  mkdir -p src
  echo "export const VERSION = '1.0.0';" > src/version.js
  echo "console.log('test');" > src/index.js
  # Files are untracked (not added)

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # Should have auto-committed
  COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)
  [ "$COMMITS_AHEAD" -eq 2 ]

  # Files should be committed
  git diff --quiet HEAD -- src/version.js
  git diff --quiet HEAD -- src/index.js
}

@test "check_dev_session_output: auto-commit excludes .gitignore changes" {
  # Simulate sharkrite's .gitignore modification + real code changes
  echo ".rite" >> .gitignore
  echo "function bar() { return 'test'; }" > utils.js

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # utils.js should be committed
  git diff --quiet HEAD -- utils.js

  # .gitignore should NOT be in the commit tree.
  # Use git ls-tree (checks HEAD's actual tree) rather than git diff
  # (which exits 0 for both "file committed with same content" and
  # "file untracked" — giving a false pass regardless of outcome).
  # Pattern matches the worktree-symlink test above.
  ! git ls-tree HEAD -- .gitignore | grep -q .gitignore
}

@test "check_dev_session_output: auto-commit excludes worktree symlinks" {
  # Simulate worktree symlinks being present (shouldn't happen but guard should handle)
  ln -s /some/path/.rite .rite
  ln -s /some/path/.claude .claude
  echo "const config = {};" > config.js

  # Add them (simulate accidental staging)
  git add .rite .claude config.js 2>/dev/null || true

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # config.js should be committed
  git diff --quiet HEAD -- config.js

  # Symlinks should NOT be in the commit
  ! git ls-tree HEAD | grep -q '.rite'
  ! git ls-tree HEAD | grep -q '.claude'
}

@test "check_dev_session_output: logs diagnostic on auto-commit" {
  # Create log file
  export RITE_LOG_FILE=$(mktemp)

  # Simulate uncommitted changes
  echo "test" > file.txt

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # Diagnostic log should contain AUTO_COMMIT entry
  grep -q "\[diag\].*AUTO_COMMIT" "$RITE_LOG_FILE"
  grep -q "issue=42" "$RITE_LOG_FILE"
  grep -q "reason=dev_session_uncommitted" "$RITE_LOG_FILE"

  # Clean up
  rm -f "$RITE_LOG_FILE"
}

@test "check_dev_session_output: prints user-friendly messages on auto-commit" {
  # Simulate uncommitted changes
  echo "test" > file.txt

  # Run the guard and capture output
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # Output should inform user about auto-commit (info-level, single
  # condensed result line — no warning-level framing for a recovered
  # condition; see "no loud benign warnings")
  [[ "$output" =~ "Auto-committing" ]]
  [[ "$output" =~ "workflow proceeding normally" ]]
  [[ "$output" =~ "verify completeness in PR review" ]]
  [[ ! "$output" =~ "ended without committing" ]]
}

@test "check_dev_session_output: no action when real commits exist" {
  # Simulate Claude making a proper commit
  echo "const VERSION = '2.0.0';" > version.js
  git add version.js
  git commit -m "feat: add version constant" --quiet

  # Run the guard
  run check_dev_session_output

  # Should succeed with no output (silent success)
  [ "$status" -eq 0 ]

  # Should not create additional commits
  COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)
  [ "$COMMITS_AHEAD" -eq 2 ]  # init + real commit (no auto-commit)
}
