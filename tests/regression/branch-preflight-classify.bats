#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/branch-preflight.sh
# tests/regression/branch-preflight-classify.bats
# Tests for branch preflight classification (5 states)
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

  cd "$FIXTURE_REPO"

  # Source the preflight library
  source "$RITE_LIB_DIR/utils/branch-preflight.sh"
}

teardown() {
  teardown_test_tmpdir
}

@test "classify: HEALTHY - real work, up-to-date, clean tree" {
  # Test: Branch has 2 real commits, up-to-date with main, clean tree
  # Expected: Returns 0 (HEALTHY)

  local issue_number=42
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with init commit + real work
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -m "Add feature implementation" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Classify
  set +e
  classify_branch_health "$issue_number" "$branch_name" "$worktree_path"
  local exit_code=$?
  set -e

  # Should return 0 (HEALTHY)
  [ "$exit_code" -eq 0 ]
}

@test "classify: EMPTY_INIT - only init commit, up-to-date" {
  # Test: Branch has ONLY init commit, no other work, up-to-date with main
  # Expected: Returns 3 (EMPTY_INIT)

  local issue_number=43
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with ONLY init commit
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Classify
  set +e
  classify_branch_health "$issue_number" "$branch_name" "$worktree_path"
  local exit_code=$?
  set -e

  # Should return 3 (EMPTY_INIT)
  [ "$exit_code" -eq 3 ]
}

@test "classify: DIVERGENT_NO_WORK - only init commit, behind main" {
  # Test: Branch has ONLY init commit AND is behind main
  # Expected: Returns 4 (DIVERGENT_NO_WORK)

  local issue_number=44
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with init commit
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main - add commits to main
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "main work $i" > "main-work-${i}.txt"
    git add "main-work-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree for the feature branch
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Classify
  set +e
  classify_branch_health "$issue_number" "$branch_name" "$worktree_path"
  local exit_code=$?
  set -e

  # Should return 4 (DIVERGENT_NO_WORK)
  [ "$exit_code" -eq 4 ]
}

@test "classify: STALE - real work, behind main" {
  # Test: Branch has real work but is behind main
  # Expected: Returns 2 (STALE)

  local issue_number=45
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with real work
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -m "Add feature implementation" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main work" > main-work.txt
  git add main-work.txt
  git commit -m "Main commit" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Classify
  set +e
  classify_branch_health "$issue_number" "$branch_name" "$worktree_path"
  local exit_code=$?
  set -e

  # Should return 2 (STALE)
  [ "$exit_code" -eq 2 ]
}

@test "classify: UNCOMMITTED_PRESERVED - uncommitted changes" {
  # Test: Branch has uncommitted changes in working tree
  # Expected: Returns 5 (UNCOMMITTED_PRESERVED)

  local issue_number=46
  local branch_name="fix/test-issue-${issue_number}"

  # Create feature branch with real work
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -m "Add feature implementation" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-${issue_number}"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Add uncommitted changes
  echo "uncommitted work" > "$worktree_path/uncommitted.txt"

  # Classify
  set +e
  classify_branch_health "$issue_number" "$branch_name" "$worktree_path"
  local exit_code=$?
  set -e

  # Should return 5 (UNCOMMITTED_PRESERVED)
  [ "$exit_code" -eq 5 ]
}
