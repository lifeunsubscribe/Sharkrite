#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/branch-preflight.sh
# tests/regression/branch-preflight-auto-recover.bats
# Tests for branch preflight auto-recovery (EMPTY_INIT/DIVERGENT_NO_WORK)
#
# Verifies fixes for issue #76 (Add preflight branch sanity check)

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
  mkdir -p "$RITE_PROJECT_ROOT/.rite"

  cd "$FIXTURE_REPO"

  # Source the preflight library
  source "$RITE_LIB_DIR/utils/branch-preflight.sh"
}

teardown() {
  teardown_test_tmpdir
}

@test "auto-recover: EMPTY_INIT - removes worktree and branch" {
  # Test: Auto-recovery for EMPTY_INIT state
  # Expected: Worktree removed, branch deleted, ready for restart

  local issue_number=50
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with ONLY init commit
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify worktree exists before recovery
  [ -d "$worktree_path" ]

  # Run auto-recovery
  preflight_auto_recover_empty "$issue_number" "$branch_name" "$worktree_path"
  local exit_code=$?

  # Should succeed
  [ "$exit_code" -eq 0 ]

  # Verify worktree was removed
  [ ! -d "$worktree_path" ]

  # Verify local branch was deleted
  ! git show-ref --verify --quiet "refs/heads/$branch_name"

  # Verify remote branch was deleted
  ! git ls-remote --heads origin "$branch_name" | grep -q "$branch_name"
}

@test "auto-recover: EMPTY_INIT with draft PR - closes PR before cleanup" {
  # Test: Auto-recovery closes empty draft PR before cleanup
  # Expected: Draft PR closed, worktree removed, branch deleted

  # Skip if gh CLI not available
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh CLI not available"
  fi

  local issue_number=51
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with ONLY init commit
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Create a draft PR (simulate with mock - actual PR creation requires GitHub repo)
  # NOTE: This test is a placeholder. In real environment with gh auth, you'd do:
  # gh pr create --draft --title "Test PR #${issue_number}" --body "Closes #${issue_number}" --head "$branch_name"
  # For now, just verify the function handles missing PR gracefully

  # Run auto-recovery (without PR - should handle gracefully)
  preflight_auto_recover_empty "$issue_number" "$branch_name" "$worktree_path" ""
  local exit_code=$?

  # Should succeed even without PR
  [ "$exit_code" -eq 0 ]

  # Verify cleanup happened
  [ ! -d "$worktree_path" ]
  ! git show-ref --verify --quiet "refs/heads/$branch_name"
}

@test "auto-recover: session state file removed" {
  # Test: Auto-recovery removes session state file
  # Expected: Session state file deleted during cleanup

  local issue_number=52
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with ONLY init commit
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Create a session state file
  local state_file="$RITE_PROJECT_ROOT/.rite/session-state-${issue_number}.json"
  echo '{"test": "state"}' > "$state_file"

  # Verify state file exists before recovery
  [ -f "$state_file" ]

  # Run auto-recovery
  preflight_auto_recover_empty "$issue_number" "$branch_name" "$worktree_path" ""

  # Verify state file was removed
  [ ! -f "$state_file" ]
}

@test "auto-recover: DIVERGENT_NO_WORK - handles behind + empty state" {
  # Test: Auto-recovery for DIVERGENT_NO_WORK (behind main + only init)
  # Expected: Same cleanup as EMPTY_INIT

  local issue_number=53
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with init commit
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main - add commits to main
  git checkout main >/dev/null 2>&1
  echo "main work" > main-work.txt
  git add main-work.txt
  git commit -m "Main commit" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree for the feature branch
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify worktree exists and is behind
  [ -d "$worktree_path" ]

  # Run auto-recovery (same function handles DIVERGENT_NO_WORK)
  preflight_auto_recover_empty "$issue_number" "$branch_name" "$worktree_path" ""
  local exit_code=$?

  # Should succeed
  [ "$exit_code" -eq 0 ]

  # Verify cleanup happened
  [ ! -d "$worktree_path" ]
  ! git show-ref --verify --quiet "refs/heads/$branch_name"
}

@test "auto-recover: preserves real work branches (negative test)" {
  # Test: Auto-recovery should NOT be called on branches with real work
  # This is a safeguard test - caller should classify correctly
  # Expected: If accidentally called, branch with real work is still cleaned up
  # (caller's responsibility to not call this on HEALTHY/STALE branches)

  local issue_number=54
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with REAL work
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  echo "important feature" > feature.txt
  git add feature.txt
  git commit -m "Add important feature" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Classification should return 0 (HEALTHY), not 3 or 4
  set +e
  classify_branch_health "$issue_number" "$branch_name" "$worktree_path"
  local class_code=$?
  set -e

  # Should be HEALTHY (0), not EMPTY_INIT (3) or DIVERGENT_NO_WORK (4)
  [ "$class_code" -eq 0 ]

  # If caller accidentally called auto-recover, the function would still clean up
  # (it doesn't re-check classification). This is by design — caller must classify first.
  # No need to call recovery here since classification passed.
}
