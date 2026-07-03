#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh
# tests/regression/stale-branch-rebase.bats - Stale branch rebase tests
#
# Tests that stale branches are brought up to date via rebase (not merge).
# Verifies fixes for issue #74 (rebase stale branches instead of merging main).

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

  # Source the stale-branch library
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

@test "rebase succeeds - branch behind, no conflicts" {
  # Test: Branch is 3 commits behind main, has 2 commits of its own, no conflicts
  # Expected: Rebase succeeds, branch is now up to date, force-push succeeds

  # Create feature branch with 2 commits
  local branch_name="fix/test-issue-42"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work 1" > feature1.txt
  git add feature1.txt
  git commit -m "Feature commit 1" >/dev/null 2>&1
  echo "feature work 2" > feature2.txt
  git add feature2.txt
  git commit -m "Feature commit 2" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main - add 3 commits with new files
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "main work $i" > "main-work-${i}.txt"
    git add "main-work-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree for the feature branch
  local worktree_path="$RITE_WORKTREE_DIR/issue-42"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Record commit count before rebase
  local commits_before
  commits_before=$(git -C "$worktree_path" rev-list --count HEAD 2>/dev/null)

  # Run rebase function
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  # Should succeed
  [ "$exit_code" -eq 0 ]

  # Verify branch now has main's new files
  [ -f "$worktree_path/main-work-1.txt" ]
  [ -f "$worktree_path/main-work-2.txt" ]
  [ -f "$worktree_path/main-work-3.txt" ]

  # Verify feature files still present
  [ -f "$worktree_path/feature1.txt" ]
  [ -f "$worktree_path/feature2.txt" ]

  # Verify branch is ahead of origin/main by exactly 2 commits (the feature commits)
  local commits_ahead
  commits_ahead=$(git -C "$worktree_path" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$commits_ahead" -eq 2 ]

  # Verify no merge commits (rebase doesn't create merge commits)
  local merge_commit_count
  merge_commit_count=$(git -C "$worktree_path" log origin/main..HEAD --merges --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$merge_commit_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "rebase conflicts - abort cleanly" {
  # Test: Branch modifies same file as main, rebase has conflicts
  # Expected: Rebase aborts cleanly, no leftover rebase state, function returns non-zero

  # Stub attempt_claude_merge_resolution to return 1 so this test deterministically
  # exercises the plain auto-bail path (print_error + return 1). Without the stub,
  # stale-branch.sh sources conflict-resolver.sh (present in lib/utils/), the resolver
  # is defined, and the auto-mode conflict path runs a real Claude session whose result
  # is non-deterministic (PR #103 wired this in after this test was written in PR #86).
  attempt_claude_merge_resolution() { return 1; }

  # Create feature branch that modifies README.md
  local branch_name="fix/conflicting-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "Feature line" >> README.md
  git add README.md
  git commit -m "Feature changes README" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Main also modifies README.md (conflict!)
  git checkout main >/dev/null 2>&1
  echo "Main line (conflict)" >> README.md
  git add README.md
  git commit -m "Main changes README" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-conflict"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Run rebase function (should fail). Use `run` so the expected non-zero return is
  # captured in $status rather than tripping bats' errexit on the bare command (the
  # auto-mode conflict bail returns 1 from stale-branch.sh — see the sibling test in
  # stale-branch-dirty-worktree.bats which uses the same pattern).
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"

  # Should return non-zero (failure)
  [ "$status" -ne 0 ]

  # Verify no leftover rebase state
  [ ! -d "$worktree_path/.git/rebase-merge" ]
  [ ! -d "$worktree_path/.git/rebase-apply" ]

  # Verify branch is still on the original commit (rebase aborted)
  local current_message
  current_message=$(git -C "$worktree_path" log -1 --format=%s HEAD 2>/dev/null)
  [ "$current_message" = "Feature changes README" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "rebase uses force-with-lease push" {
  # Test: After successful rebase, push uses --force-with-lease (not regular push)
  # Expected: History is rewritten, regular push would fail, force-with-lease succeeds

  # Create feature branch
  local branch_name="fix/force-lease-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main work" > main.txt
  git add main.txt
  git commit -m "Main work" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-force-lease"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Record original commit SHA (before rebase)
  local original_sha
  original_sha=$(git -C "$worktree_path" rev-parse HEAD)

  # Run rebase
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Verify commit SHA changed (history was rewritten)
  local new_sha
  new_sha=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$original_sha" != "$new_sha" ]

  # Verify remote branch was updated (force-push succeeded)
  local remote_sha
  remote_sha=$(git -C "$worktree_path" rev-parse origin/"$branch_name")
  [ "$new_sha" = "$remote_sha" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "rebase vs merge - no false conflicts with new files" {
  # Test: Reproduce the dogfooding scenario - main adds files branch doesn't have
  # Expected: Rebase handles cleanly (no conflicts), merge would report conflicts

  # Create feature branch (based on old main with only README.md)
  local branch_name="fix/dogfood-repro"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "fix for issue" > fix.txt
  git add fix.txt
  git commit -m "Fix implementation" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Main adds several new files (like bats tests in the real scenario)
  git checkout main >/dev/null 2>&1
  for i in 1 2 3 4; do
    echo "new test $i" > "test-${i}.bats"
    git add "test-${i}.bats"
    git commit -m "Add test file $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-dogfood"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify new files don't exist in branch yet
  [ ! -f "$worktree_path/test-1.bats" ]

  # Run rebase (should succeed without conflicts)
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Verify new files now present
  [ -f "$worktree_path/test-1.bats" ]
  [ -f "$worktree_path/test-2.bats" ]
  [ -f "$worktree_path/test-3.bats" ]
  [ -f "$worktree_path/test-4.bats" ]

  # Verify fix commit is still present
  [ -f "$worktree_path/fix.txt" ]

  # Verify branch is 1 commit ahead of main (the fix commit, rebased)
  local commits_ahead
  commits_ahead=$(git -C "$worktree_path" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$commits_ahead" -eq 1 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_stale_branch uses rebase for below-threshold branches" {
  # Integration test: check_stale_branch function uses rebase (not merge)
  # Test: Branch is 3 commits behind (below default threshold of 10)
  # Expected: Function calls _stale_rebase_onto_main and succeeds

  # Create feature branch
  local branch_name="fix/integration-test-55"
  local issue_number="55"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Work on issue #55" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main by 3 commits (below threshold)
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "diverge $i" > "diverge-${i}.txt"
    git add "diverge-${i}.txt"
    git commit -m "Main divergence $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-55"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Create mock PR (issue not used in this test but required by function signature)
  local pr_number="99"

  # Run check_stale_branch with auto mode
  check_stale_branch "$worktree_path" "$pr_number" "$issue_number" "auto"
  local exit_code=$?

  # Should succeed (exit 0 = continue workflow)
  [ "$exit_code" -eq 0 ]

  # Verify rebase happened - main's new files should be present
  [ -f "$worktree_path/diverge-1.txt" ]
  [ -f "$worktree_path/diverge-2.txt" ]
  [ -f "$worktree_path/diverge-3.txt" ]

  # Verify no merge commits
  local merge_count
  merge_count=$(git -C "$worktree_path" log origin/main..HEAD --merges --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$merge_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}
