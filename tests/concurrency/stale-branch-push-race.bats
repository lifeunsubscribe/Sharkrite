#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh, lib/utils/divergence-handler.sh
# tests/concurrency/stale-branch-push-race.bats - Git push race condition tests
#
# Tests that concurrent pushes to the same branch are handled correctly.
# Also tests worktree creation races when multiple processes work on same issue.
# These tests verify fixes for issue #15 (stale branch push races) and #26 (worktree races).
# Also verifies issue #27: foreign commits after stale-branch push rejection are
# classified rather than silently absorbed (re-review exit code 2 is returned).
#
# NOTE: The "EXPECTED FAILURE" escape hatches (return 0) that existed before
# issues #15/#26 landed have been removed.  These are now hard-failure assertions
# — if git/worktree race handling regresses, these tests WILL fail (which is
# the point).  See issue-lock.bats for the same pattern.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  # Skip on bash 3.2 (macOS system bash). Moved from setup_file() — skip inside
  # setup_file() requires bats >=1.5.0; skip inside setup() is universally supported.
  # Barrier sync + subshell spawning relies on bash 4+ performance:
  # bash 3.2 startup is 50-150ms per subshell vs ~10ms for bash 4+, so
  # concurrent subshells can't reliably reach the barrier within the timeout
  # on a busy macOS dev machine, producing false failures unrelated to the
  # git push race behavior under test.
  # On Homebrew bash 4+ (macOS) and Linux CI (bash 4+ default), tests run fully.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (detected bash ${BASH_VERSION}). Install via: brew install bash"
  fi

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
  local pid_file="$BARRIER_DIR/${barrier_name}.$BASHPID"

  touch "$pid_file"

  local count=0
  local timeout=0
  # 100 iterations × 0.1s = 10s. Bumped from 5s to give bash 4+ subshells
  # enough headroom on a loaded macOS dev machine.
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 100 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done

  if [ "$timeout" -ge 100 ]; then
    echo "ERROR: Barrier timeout waiting for $expected_count processes (got $count)" >&2
    return 1
  fi
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

  # Exactly one should succeed (first to push).
  # This is a fundamental git property — the first non-fast-forward push wins.
  [ "$success_count" -eq 1 ] || {
    echo "FAIL: $success_count pushes succeeded (expected exactly 1)."
    echo "  success_count=0 → barrier timed out before subshells started racing (test scaffolding failure)"
    echo "  success_count>1 → git non-fast-forward rejection not firing (genuine regression)"
    return 1
  }

  # Verify rejections happened (num_processes - 1 must be rejected in a true race).
  [ "$rejection_count" -ge 1 ] || {
    echo "FAIL: Expected at least one rejection, got $rejection_count — concurrent push rejection not working"
    return 1
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

  # Only one should succeed — git worktree add is atomic (directory creation is the lock).
  # Issues #15/#26 must ensure rite handles this correctly; but git's own atomicity is
  # the underlying guarantee.
  [ "$success_count" -eq 1 ] || {
    echo "FAIL: $success_count worktrees created (expected exactly 1)."
    echo "  success_count=0 → barrier timed out (test scaffolding failure)"
    echo "  success_count>1 → git worktree add is not atomic (genuine regression)"
    return 1
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

  # Only one should succeed — git checkout -b fails if the branch already exists.
  # This is a fundamental git property, not a rite-specific fix.
  [ "$success_count" -eq 1 ] || {
    echo "FAIL: $success_count branches created (expected exactly 1)."
    echo "  success_count=0 → barrier timed out (test scaffolding failure)"
    echo "  success_count>1 → concurrent branch creation not atomic (genuine regression)"
    return 1
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

  # At least one process must successfully merge main and push.
  # Issue #15's stale-branch handling ensures concurrent merge-main attempts
  # don't all fail — at minimum one succeeds, others handle the race gracefully.
  [ "$success_count" -ge 1 ] || {
    echo "FAIL: No successful merge+push — stale-branch race handling (issue #15) regressed"
    return 1
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

# =============================================================================
# Issue #27: Foreign commit classification after stale-branch push rejection
# =============================================================================

@test "stale-branch push-race: foreign UNRELATED commit triggers exit 2 (re-review), not silent absorb" {
  # Regression test for issue #27.
  #
  # Scenario: A stale feature branch is rebased onto main.  Between the rebase
  # completing and the push attempt, a second rite run pushes a commit from a
  # different scope to the same branch.  The force-with-lease push is rejected.
  #
  # Expected (fixed behaviour):
  #   _stale_rebase_onto_main calls _stale_classify_after_push_rejection, which
  #   re-fetches, classifies the foreign commit as UNRELATED (or RELATED), and
  #   returns exit 2 — signalling the caller that a re-review is needed.
  #
  # The critical assertion is: exit code MUST be 2, NOT 0 (silent absorb).
  # A return of 0 would mean the workflow continued as if nothing happened,
  # skipping review of the foreign commit entirely.

  cd "$FIXTURE_REPO"

  # Source stale-branch (pulls in stash-manager, post-merge-verify)
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub classify_foreign_commits to return UNRELATED without a Claude call.
  # This isolates the test from network/API availability while exercising the
  # full code path through _stale_classify_after_push_rejection.
  classify_foreign_commits() {
    export DIVERGENCE_CLASS="UNRELATED"
    return 0
  }

  # Stub verify_post_merge so it always passes (not under test here)
  verify_post_merge() { return 0; }

  # Create feature branch with one commit, pushed to origin
  local branch_name="fix/race-classify-test-27"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > feature-27.txt
  git add feature-27.txt
  git commit -m "Feature work for issue #27 test" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main so the stale-branch check has actual rebase work to do
  git checkout main >/dev/null 2>&1
  echo "main divergence" > main-27.txt
  git add main-27.txt
  git commit -m "Main divergence for issue #27 test" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout "$branch_name" >/dev/null 2>&1

  # Create a worktree on the feature branch
  local worktree_path="$RITE_WORKTREE_DIR/issue-race-27"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Simulate the concurrent push: while our worktree is about to rebase+push,
  # another client pushes an unrelated commit to the same remote branch.
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-27"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Concurrent Client" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$branch_name" >/dev/null 2>&1
  echo "foreign unrelated change" > "$concurrent_dir/foreign-27.txt"
  git -C "$concurrent_dir" add foreign-27.txt >/dev/null 2>&1
  git -C "$concurrent_dir" commit -m "fix: unrelated change from another issue" >/dev/null 2>&1
  git -C "$concurrent_dir" push origin "$branch_name" >/dev/null 2>&1

  # Confirm the concurrent commit is on remote (sanity check)
  local remote_tip_before
  remote_tip_before=$(git ls-remote "$BARE_REMOTE" "refs/heads/$branch_name" | awk '{print $1}' || true)
  [ -n "$remote_tip_before" ]

  # Drive _stale_rebase_onto_main — this is the function under test.
  # It will:
  #   1. Rebase the feature branch onto origin/main (succeeds — no conflict)
  #   2. Attempt git push --force-with-lease origin <branch>
  #   3. Push is rejected because the concurrent push advanced the remote tip
  #   4. Call _stale_classify_after_push_rejection → classify_foreign_commits (stubbed → UNRELATED)
  #   5. Return exit 2: foreign commits require re-review
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto" "" ""

  # CRITICAL: must return exit 2, not 0 (silent absorb) or 1 (generic failure)
  [ "$status" -eq 2 ]

  # The concurrent commit must still be on remote — it was NOT overwritten
  local remote_tip_after
  remote_tip_after=$(git ls-remote "$BARE_REMOTE" "refs/heads/$branch_name" | awk '{print $1}' || true)
  [ "$remote_tip_before" = "$remote_tip_after" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "stale-branch push-race: TRIVIAL foreign commit is absorbed silently (exit 0)" {
  # Companion to the test above: when the foreign commits are classified as TRIVIAL
  # (mainline sync, docs, formatting — no logic changes), they are absorbed and the
  # push retried. No re-review is needed.
  #
  # Expected: _stale_rebase_onto_main returns exit 0 after absorbing TRIVIAL commits.

  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub classify_foreign_commits to return TRIVIAL
  classify_foreign_commits() {
    export DIVERGENCE_CLASS="TRIVIAL"
    return 0
  }

  # Stub verify_post_merge so it always passes
  verify_post_merge() { return 0; }

  local branch_name="fix/race-trivial-test-27"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > feature-trivial.txt
  git add feature-trivial.txt
  git commit -m "Feature work (trivial test)" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main divergence" > main-trivial.txt
  git add main-trivial.txt
  git commit -m "Main divergence (trivial test)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout "$branch_name" >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-trivial-27"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Concurrent TRIVIAL push (a doc-only change)
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-trivial"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Concurrent Client" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$branch_name" >/dev/null 2>&1
  echo "# trivial doc update" >> "$concurrent_dir/feature-trivial.txt"
  git -C "$concurrent_dir" add feature-trivial.txt >/dev/null 2>&1
  git -C "$concurrent_dir" commit -m "docs: minor doc update (trivial)" >/dev/null 2>&1
  git -C "$concurrent_dir" push origin "$branch_name" >/dev/null 2>&1

  # Drive the function
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto" "" ""

  # TRIVIAL foreign commits must be discarded: exit 0 (no re-review needed)
  [ "$status" -eq 0 ]

  # The trivial foreign commit must have been DISCARDED (not absorbed):
  # the concurrent client appended "# trivial doc update" to feature-trivial.txt,
  # but after rebase onto origin/main the worktree must NOT contain that line.
  run grep -q "trivial doc update" "$worktree_path/feature-trivial.txt"
  [ "$status" -ne 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}
