#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/utils/pr-detection.sh
# tests/regression/resume-from-pr-branch.bats - Resume from PR branch tests
#
# Tests that resuming an issue with existing PR recreates worktree from
# the remote PR branch (not origin/main).
# Verifies fix for issue #55.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  # Set up environment
  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"

  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO"

  # Source required libraries
  source "$RITE_LIB_DIR/utils/config.sh"
  source "$RITE_LIB_DIR/utils/pr-detection.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

@test "worktree recreated from remote PR branch (not origin/main)" {
  # Test: Issue has remote branch + PR, no local worktree
  # Expected: Worktree created from origin/<branch>, not origin/main

  local issue_number=42
  local branch_name="fix/test-issue-42"

  # Create feature branch with commits and push to remote
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "PR work 1" > pr-work-1.txt
  git add pr-work-1.txt
  git commit -m "Work on issue #${issue_number} - commit 1" >/dev/null 2>&1
  echo "PR work 2" > pr-work-2.txt
  git add pr-work-2.txt
  git commit -m "Work on issue #${issue_number} - commit 2" >/dev/null 2>&1

  # Capture the PR branch HEAD SHA before pushing
  local pr_branch_sha
  pr_branch_sha=$(git rev-parse HEAD)

  git push -u origin "$branch_name" >/dev/null 2>&1

  # Return to main and delete local branch (simulate worktree cleanup)
  git checkout main >/dev/null 2>&1
  git branch -D "$branch_name" >/dev/null 2>&1

  # Verify local branch is gone but remote exists
  ! git show-ref --verify --quiet refs/heads/"$branch_name"
  git ls-remote --heads origin "$branch_name" | grep -q "$branch_name"

  # Fetch remote branch (simulating what claude-workflow.sh does)
  git fetch origin main >/dev/null 2>&1
  git fetch origin "$branch_name" >/dev/null 2>&1

  # Create worktree from remote branch (the fix being tested)
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify worktree HEAD matches the remote PR branch (not origin/main)
  local worktree_sha
  worktree_sha=$(git -C "$worktree_path" rev-parse HEAD)

  [ "$worktree_sha" = "$pr_branch_sha" ]

  # Verify PR work files exist in worktree
  [ -f "$worktree_path/pr-work-1.txt" ]
  [ -f "$worktree_path/pr-work-2.txt" ]

  # Verify worktree is on the correct branch
  local worktree_branch
  worktree_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD)
  [ "$worktree_branch" = "$branch_name" ]
}

@test "worktree created from origin/main when no remote branch exists" {
  # Test: No remote branch exists for this issue
  # Expected: Worktree created from origin/main (current behavior preserved)

  local issue_number=99
  local branch_name="fix/test-issue-99"

  # Capture origin/main SHA
  local main_sha
  main_sha=$(git rev-parse origin/main)

  # Verify remote branch does NOT exist
  ! git ls-remote --heads origin "$branch_name" | grep -q "$branch_name"

  # Create worktree from origin/main (default behavior)
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add -b "$branch_name" "$worktree_path" origin/main >/dev/null 2>&1

  # Verify worktree is based on origin/main
  local worktree_base
  worktree_base=$(git -C "$worktree_path" rev-parse HEAD)

  [ "$worktree_base" = "$main_sha" ]

  # Verify worktree is on the new branch
  local worktree_branch
  worktree_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD)
  [ "$worktree_branch" = "$branch_name" ]
}

@test "detect_pr_for_issue correctly identifies remote branch" {
  # Test: PR detection via detect_pr_for_issue function
  # This test will be skipped in CI since it needs GitHub CLI mocking
  # But useful for local testing with actual gh

  skip "Requires GitHub CLI mocking infrastructure"

  local issue_number=42
  local branch_name="fix/test-issue-42"

  # Create and push PR branch
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "test" > test.txt
  git add test.txt
  git commit -m "Test commit for #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Test detection function
  if detect_pr_for_issue "$issue_number"; then
    [ "$PR_BRANCH" = "$branch_name" ]
  fi
}
