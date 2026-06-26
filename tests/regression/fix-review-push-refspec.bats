#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Test suite for issue #10: Fix bare git push in fix-review path
#
# Verifies that the fix-review push uses an explicit refspec (origin <branch>)
# instead of bare 'git push', which could push to origin/main if the worktree
# was created with 'git worktree add -b feat origin/main'

setup() {
  # Create a mock test directory structure
  TEST_DIR=$(mktemp -d)
  export TEST_DIR

  # Mock script that simulates the fix-review push logic
  MOCK_SCRIPT="$TEST_DIR/mock-fix-review.sh"

  # Create git environment
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create initial commit on main
  echo "initial" > README.md
  git add README.md
  git commit -q -m "Initial commit"
  git branch -M main

  # Set up a fake remote
  REMOTE_DIR="$TEST_DIR/remote"
  git init -q --bare "$REMOTE_DIR"
  git remote add origin "$REMOTE_DIR"
  git push -q origin main
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "fix-review push uses explicit refspec, not bare git push" {
  # Verify the actual code doesn't contain bare git push
  BARE_PUSH_COUNT=$(grep -c "if ! git push; then" "$BATS_TEST_DIRNAME/../../lib/core/claude-workflow.sh" || true)

  # Should be 0 - the bug is fixed
  [ "$BARE_PUSH_COUNT" -eq 0 ]

  # Verify it uses origin + branch (match semantic pattern, not specific variable name)
  # Matches: git push origin "$VAR" or git push origin "${VAR}"
  EXPLICIT_PUSH_COUNT=$(grep -cE 'git push origin "\$(\{[^}]+\}|[a-zA-Z_][a-zA-Z0-9_]*)"' "$BATS_TEST_DIRNAME/../../lib/core/claude-workflow.sh" || true)

  # Should be at least 1
  [ "$EXPLICIT_PUSH_COUNT" -ge 1 ]
}

@test "worktree created from origin/main doesn't push to main" {
  # Create a feature branch from origin/main (simulating git worktree add)
  git checkout -q -b fix/test-feature origin/main

  # Make a change
  echo "fix applied" > fix.txt
  git add fix.txt
  git commit -q -m "fix: apply review fix"

  # Simulate the fixed push logic (explicit refspec)
  _fix_branch=$(git branch --show-current)
  git push -q origin "$_fix_branch"

  # Verify the feature branch exists on remote
  FEATURE_ON_REMOTE=$(git ls-remote origin "refs/heads/$_fix_branch" | wc -l | tr -d ' ')
  [ "$FEATURE_ON_REMOTE" -eq 1 ]

  # Verify main wasn't changed (only has the initial commit)
  MAIN_COMMITS=$(git rev-list origin/main --count)
  [ "$MAIN_COMMITS" -eq 1 ]

  # Verify the feature branch has the new commit
  FEATURE_COMMITS=$(git rev-list "origin/$_fix_branch" --count)
  [ "$FEATURE_COMMITS" -eq 2 ]
}

@test "lint detects bare git push in test files" {
  # Create a test file with bare git push
  TEST_FILE="$TEST_DIR/bad-push.sh"
  cat > "$TEST_FILE" <<'EOF'
#!/usr/bin/env bash
# Re-source guard
if declare -f _bad_push_fn >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_bad_push_fn() {
  git add -A
  git commit -m "fix"
  git push
}
EOF

  # Create a minimal sharkrite structure for the linter
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/lib" "$TEST_DIR/tools"
  cp "$TEST_FILE" "$TEST_DIR/lib/test.sh"

  # Copy the lint script into the test directory structure
  # This way the script's own PROJECT_ROOT detection will find our test files
  REAL_LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"
  TEST_LINT_SCRIPT="$TEST_DIR/tools/sharkrite-lint.sh"
  cp "$REAL_LINT_SCRIPT" "$TEST_LINT_SCRIPT"

  # Run the linter from within the test directory
  # PROJECT_ROOT will resolve to $TEST_DIR via the script's own path detection
  run bash "$TEST_LINT_SCRIPT" 2>&1

  [ "$status" -ne 0 ]
  [[ "$output" =~ "GIT_PUSH_NO_REFSPEC" ]]
}

@test "lint accepts git push with explicit origin and branch" {
  # Create a test file with correct git push
  TEST_FILE="$TEST_DIR/good-push.sh"
  cat > "$TEST_FILE" <<'EOF'
#!/usr/bin/env bash
# Re-source guard
if declare -f _good_push_fn >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_good_push_fn() {
  _fix_branch=$(git branch --show-current)
  git add -A
  git commit -m "fix"
  git push origin "$_fix_branch"
}
EOF

  # Create a minimal sharkrite structure for the linter
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/lib" "$TEST_DIR/tools"
  cp "$TEST_FILE" "$TEST_DIR/lib/test.sh"

  # Copy the lint script into the test directory structure
  # This way the script's own PROJECT_ROOT detection will find our test files
  REAL_LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"
  TEST_LINT_SCRIPT="$TEST_DIR/tools/sharkrite-lint.sh"
  cp "$REAL_LINT_SCRIPT" "$TEST_LINT_SCRIPT"

  # Run the linter from within the test directory
  # PROJECT_ROOT will resolve to $TEST_DIR via the script's own path detection
  run bash "$TEST_LINT_SCRIPT" 2>&1

  # Should pass (exit 0) and not mention GIT_PUSH_NO_REFSPEC
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GIT_PUSH_NO_REFSPEC" ]]
}
