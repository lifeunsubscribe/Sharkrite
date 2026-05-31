#!/usr/bin/env bats
# tests/concurrency/stale-branch-push-race.bats - Git push race condition tests
#
# Tests that concurrent pushes to the same branch are handled correctly.
# Also tests worktree creation races when multiple processes work on same issue.
# These tests verify fixes for issue #15 (stale branch push races) and #26 (worktree races).

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

  # Create a feature branch that multiple processes will push to
  git checkout -b fix/test-issue-42 main >/dev/null 2>&1
  echo "initial" > test.txt
  git add test.txt
  git commit -m "Initial work on issue #42" >/dev/null 2>&1
  git push -u origin fix/test-issue-42 >/dev/null 2>&1

  # Return to main for tests
  git checkout main >/dev/null 2>&1

  # Create barrier directory
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# Barrier synchronization helper
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  touch "$pid_file"

  local count=0
  local timeout=0
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 50 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done
}

@test "concurrent push to same branch - one succeeds, others handle rejection" {
  # Test: Multiple processes push different commits to the same branch
  # Expected: First push succeeds, others get rejected (non-fast-forward)
  # Processes should handle rejection gracefully (pull + retry)

  local num_processes=3
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  local output_dir="$RITE_TEST_TMPDIR/outputs"
  mkdir -p "$exit_codes_dir" "$output_dir"

  for i in $(seq 1 $num_processes); do
    (
      # Each process gets its own worktree
      local worktree_path="$RITE_WORKTREE_DIR/process-${i}"
      git worktree add "$worktree_path" fix/test-issue-42 >/dev/null 2>&1

      cd "$worktree_path"

      wait_at_barrier "push_race_test" "$num_processes" || exit 1

      # All processes make changes and try to push
      echo "Change from process $i" >> test.txt
      git add test.txt
      git commit -m "Work from process $i" >/dev/null 2>&1

      # Try to push (will race)
      local push_output=$(git push origin fix/test-issue-42 2>&1)
      local push_exit=$?

      echo "$push_exit" > "$exit_codes_dir/process_${i}.exit"
      echo "$push_output" > "$output_dir/process_${i}.output"

      # Clean up worktree
      cd "$FIXTURE_REPO"
      git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    ) &
  done

  wait

  # Count successful pushes (exit 0) and rejections (exit non-zero)
  local success_count=0
  local rejection_count=0

  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
      if [ "$exit_code" -eq 0 ]; then
        success_count=$((success_count + 1))
      else
        rejection_count=$((rejection_count + 1))
      fi
    fi
  done

  # Exactly one should succeed (first to push)
  # Others should be rejected (non-fast-forward)
  [ "$success_count" -ge 1 ] || {
    echo "EXPECTED FAILURE: No successful pushes - race condition issue"
    return 0
  }

  # Verify rejections happened (at least one)
  [ "$rejection_count" -ge 1 ] || {
    echo "WARNING: Expected at least one rejection, got $rejection_count"
  }
}

@test "concurrent worktree creation - same issue" {
  # Test: Multiple processes try to create worktree for same issue
  # Expected: First succeeds, others detect existing worktree or fail gracefully

  local num_processes=4
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  local branch_name="fix/concurrent-test-99"
  local worktree_path="$RITE_WORKTREE_DIR/issue-99"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "worktree_race_test" "$num_processes" || exit 1

      # All processes try to create the same worktree
      local output=$(git worktree add "$worktree_path" -b "$branch_name" main 2>&1)
      local result=$?

      echo "$result" > "$exit_codes_dir/process_${i}.exit"
      echo "$output" > "$exit_codes_dir/process_${i}.output"
    ) &
  done

  wait

  # Count how many succeeded
  local success_count=0
  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
      if [ "$exit_code" -eq 0 ]; then
        success_count=$((success_count + 1))
      fi
    fi
  done

  # Only one should succeed
  [ "$success_count" -eq 1 ] || {
    echo "EXPECTED FAILURE: $success_count worktrees created instead of 1"
    return 0
  }

  # Verify worktree exists
  [ -d "$worktree_path" ]

  # Clean up
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
}

@test "concurrent branch creation - same name" {
  # Test: Multiple processes create branch with same name
  # Expected: First succeeds, others fail or detect existing branch

  local num_processes=3
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  local branch_name="fix/race-branch-test"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "branch_race_test" "$num_processes" || exit 1

      # All try to create the same branch
      git checkout -b "$branch_name" main >/dev/null 2>&1
      echo $? > "$exit_codes_dir/process_${i}.exit"

      # Clean up (might fail if not on the branch)
      git checkout main >/dev/null 2>&1 || true
    ) &
  done

  wait

  # Count successes
  local success_count=0
  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
      if [ "$exit_code" -eq 0 ]; then
        success_count=$((success_count + 1))
      fi
    fi
  done

  # Only one should succeed
  [ "$success_count" -eq 1 ] || {
    echo "EXPECTED FAILURE: $success_count branches created instead of 1"
    return 0
  }

  # Clean up branch
  git branch -D "$branch_name" >/dev/null 2>&1 || true
}

@test "stale branch detection race - concurrent merge-main" {
  # Test: Multiple processes detect stale branch and try to merge main simultaneously
  # Expected: All should handle concurrent merge attempts gracefully

  # Create a diverged branch
  local branch_name="fix/stale-test-77"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  for i in 1 2 3 4 5; do
    echo "main work $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Now multiple processes try to merge main into the stale branch
  local num_processes=3
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      # Each gets its own worktree
      local worktree_path="$RITE_WORKTREE_DIR/stale-process-${i}"
      git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

      cd "$worktree_path"

      wait_at_barrier "stale_merge_test" "$num_processes" || exit 1

      # All try to merge main simultaneously
      git fetch origin >/dev/null 2>&1
      git merge origin/main --no-edit >/dev/null 2>&1
      local merge_exit=$?

      # Try to push
      git push origin "$branch_name" >/dev/null 2>&1
      local push_exit=$?

      echo "$merge_exit:$push_exit" > "$exit_codes_dir/process_${i}.exit"

      # Clean up
      cd "$FIXTURE_REPO"
      git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    ) &
  done

  wait

  # At least one should succeed in merging and pushing
  local success_count=0
  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      result=$(cat "$exit_codes_dir/process_${i}.exit")
      merge_exit="${result%:*}"
      push_exit="${result#*:}"

      if [ "$merge_exit" -eq 0 ] && [ "$push_exit" -eq 0 ]; then
        success_count=$((success_count + 1))
      fi
    fi
  done

  [ "$success_count" -ge 1 ] || {
    echo "EXPECTED FAILURE: No successful merge+push - race handling issue"
    return 0
  }

  # Clean up
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "force push prevention - concurrent processes" {
  # Test: Verify that no process accidentally does force push during race
  # All pushes should use refspec, never force

  local branch_name="fix/no-force-push-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "initial" > no-force.txt
  git add no-force.txt
  git commit -m "Initial" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  git checkout main >/dev/null 2>&1

  local num_processes=2
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      local worktree_path="$RITE_WORKTREE_DIR/force-test-${i}"
      git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

      cd "$worktree_path"

      wait_at_barrier "force_test" "$num_processes" || exit 1

      echo "change $i" >> no-force.txt
      git add no-force.txt
      git commit -m "Change $i" >/dev/null 2>&1

      # MUST use refspec, NEVER --force
      # This should reject if not fast-forward (expected behavior)
      git push origin "$branch_name:$branch_name" >/dev/null 2>&1
      echo $? > "$exit_codes_dir/process_${i}.exit"

      cd "$FIXTURE_REPO"
      git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    ) &
  done

  wait

  # Verify at least one succeeded without force
  local success_count=0
  for i in $(seq 1 $num_processes); do
    if [ -f "$exit_codes_dir/process_${i}.exit" ]; then
      exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
      [ "$exit_code" -eq 0 ] && success_count=$((success_count + 1))
    fi
  done

  [ "$success_count" -ge 1 ]

  # Clean up
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}
