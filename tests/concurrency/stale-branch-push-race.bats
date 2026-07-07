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
      # Each process gets its own worktree on its OWN local branch, all rooted at
      # the same fix/test-issue-42 tip. git refuses `git worktree add <branch>` for
      # a branch already checked out in another worktree, so three worktrees cannot
      # all check out fix/test-issue-42 directly — give each a distinct local branch
      # (-b race-push-N) at that commit instead. They all push HEAD to the SAME
      # remote branch, which is what produces the non-fast-forward race.
      local worktree_path="$RITE_WORKTREE_DIR/process-${i}"
      git worktree add -b "race-push-${i}" "$worktree_path" fix/test-issue-42 >/dev/null 2>&1

      cd "$worktree_path"

      wait_at_barrier "push_race_test" "$num_processes" || exit 1

      # All processes make changes and try to push
      echo "Change from process $i" >> test.txt
      git add test.txt
      git commit -m "Work from process $i" >/dev/null 2>&1

      # Try to push HEAD to the shared remote branch (will race).
      # Capture the REAL exit code without the SC2155 trap (a bare
      # `local x=$(cmd)` reports the `local` builtin's status, always 0) AND
      # without letting errexit kill this subshell on a rejected push: a bare
      # `push_output=$(failing push)` under bats's inherited `set -e` aborts the
      # subshell before push_exit is read. The `&& ... || push_exit=$?` form
      # captures git push's status and keeps the compound command's status 0.
      local push_output push_exit
      push_output=$(git push origin "HEAD:fix/test-issue-42" 2>&1) && push_exit=0 || push_exit=$?

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

      # All processes try to create the same worktree.
      # Capture the REAL exit code without the SC2155 trap (`local x=$(cmd)`
      # reports the builtin's status, always 0) AND without errexit killing this
      # subshell on a losing worktree-add: a bare `output=$(failing add)` under
      # bats's inherited `set -e` would abort before result is read, so losers
      # would write no exit file at all. The `&& ... || result=$?` form captures
      # git worktree add's status and keeps the compound command's status 0, so
      # every contender records its real result.
      local output result
      output=$(git worktree add "$worktree_path" -b "$branch_name" main 2>&1) && result=0 || result=$?

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
  # Stay on main: the dedicated worktree below checks out "$branch_name", and
  # git refuses `git worktree add` for a branch already checked out elsewhere
  # (fatal: "'<branch>' is already checked out", status 128). Leaving the main
  # worktree on the feature branch here made the worktree add fail before the
  # function under test was ever reached. (universal git behaviour, not BSD)
  git checkout main >/dev/null 2>&1

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

  # The foreign commit must NOT be silently discarded. The exit-2 (RELATED/UNRELATED)
  # path INTEGRATES the foreign commit — it rebases local HEAD onto
  # origin/$branch_name (absorbing the foreign commit) and force-pushes the combined
  # history, then returns 2 so the caller re-enters Phase 2→3 for review
  # (stale-branch.sh:474-480). The remote tip therefore legitimately ADVANCES to the
  # integrated HEAD; asserting tip-equality would encode the wrong contract. What
  # matters is that the foreign work survives in the remote history (preserved for
  # the re-review), not overwritten/lost.
  local _insp="$RITE_TEST_TMPDIR/inspect-27"
  git clone "$BARE_REMOTE" "$_insp" >/dev/null 2>&1
  git -C "$_insp" checkout "$branch_name" >/dev/null 2>&1

  # The foreign commit's file must be present in the remote branch tree.
  [ -f "$_insp/foreign-27.txt" ] || {
    echo "FAIL: foreign-27.txt missing from remote $branch_name — foreign commit was silently discarded, not integrated"
    git -C "$_insp" log --oneline | head -10
    return 1
  }

  # And the foreign commit must be reachable in the remote branch history.
  run git -C "$_insp" log --oneline "$branch_name"
  [[ "$output" == *"unrelated change from another issue"* ]] || {
    echo "FAIL: foreign commit not found in remote history — it was overwritten rather than integrated"
    echo "$output"
    return 1
  }

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "stale-branch push-race: TRIVIAL foreign commit that is content-empty vs local is discarded (exit 0)" {
  # When the foreign commits are classified as TRIVIAL AND their net diff vs our
  # local HEAD is empty (pure mainline-sync that brings in no new file content),
  # they are discarded without re-review. This pins the "pure sync discard" behavior.
  #
  # Scenario: The concurrent push is a merge commit that merges main into the feature
  # branch, but the feature branch already has the same file state as main (no conflict
  # resolutions, no extra lines). The diff between local HEAD and remote HEAD is empty.
  #
  # Expected: _stale_rebase_onto_main returns exit 0 (content-empty, discard safe).

  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub classify_foreign_commits to return TRIVIAL (simulates mainline-sync classification)
  classify_foreign_commits() {
    export DIVERGENCE_CLASS="TRIVIAL"
    return 0
  }

  # Stub verify_post_merge so it always passes
  verify_post_merge() { return 0; }

  local branch_name="fix/race-trivial-content-empty-27"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > feature-ce.txt
  git add feature-ce.txt
  git commit -m "Feature work (content-empty trivial test)" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main divergence" > main-ce.txt
  git add main-ce.txt
  git commit -m "Main divergence (content-empty trivial test)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-ce-27"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Concurrent push that is content-IDENTICAL to the worktree's current HEAD:
  # clone the remote at the worktree's current tip, create a "merge" commit that
  # has no net diff vs the feature branch tip (same tree), and push it.
  # We simulate this by creating an empty commit (--allow-empty) — its tree is
  # identical to HEAD so git diff local..remote is empty.
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-ce"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Concurrent Client" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$branch_name" >/dev/null 2>&1
  # Empty commit: no file changes — the tree at remote_head equals tree at local_head
  git -C "$concurrent_dir" commit --allow-empty -m "Merge branch 'main' into $branch_name" >/dev/null 2>&1
  git -C "$concurrent_dir" push origin "$branch_name" >/dev/null 2>&1

  # Drive the function
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto" "" ""

  # Content-empty TRIVIAL: must discard (exit 0, no re-review)
  [ "$status" -eq 0 ]

  # No new content from the empty foreign commit should appear (it had none to add)
  # Feature file must still exist
  [ -f "$worktree_path/feature-ce.txt" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "stale-branch push-race: TRIVIAL foreign commit with code changes is preserved via cherry-pick (exit 2, re-review)" {
  # Regression test for the Pilot ×3 incident (2026-07-06, issues #983/#984/#985/#986).
  # The bug: a collaborator's hand-fix (act() wrapper, fixture timestamp) landed on
  # the remote branch. classify_foreign_commits returned TRIVIAL (message-pattern match
  # or Claude classification). The old TRIVIAL path rebased onto base WITHOUT preserving
  # the foreign commits — force-push silently dropped them.
  #
  # Fix: TRIVIAL discard is legal ONLY when content-empty vs local HEAD. When non-empty,
  # cherry-pick the foreign commits onto the rebased branch.
  #
  # Scenario: Remote branch has a foreign commit that adds a new file (real code change).
  # classify_foreign_commits is stubbed to TRIVIAL (simulating the misclassification
  # that caused the incident). After the fix, the file must survive in the pushed branch.
  #
  # Expected: exit 2 (cherry-pick succeeded, re-review triggered for non-empty foreign
  # content), foreign file present. The TRIVIAL classification was based on commit message
  # patterns; non-empty content means real code was preserved — re-review is required
  # (consistent with RELATED/UNRELATED paths). Caller maps exit 2 → re-enter Phase 2→3.

  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub classify_foreign_commits to return TRIVIAL (simulating the Pilot ×3 mismatch)
  classify_foreign_commits() {
    export DIVERGENCE_CLASS="TRIVIAL"
    return 0
  }

  # Stub verify_post_merge so it always passes
  verify_post_merge() { return 0; }

  local branch_name="fix/race-trivial-preserve-code-27"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > feature-preserve.txt
  git add feature-preserve.txt
  git commit -m "Feature work (preserve test)" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main divergence" > main-preserve.txt
  git add main-preserve.txt
  git commit -m "Main divergence (preserve test)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-preserve-27"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Concurrent push: a collaborator's hand-fix that adds a new file (real code change)
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-preserve"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "collaborator@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Collaborator" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$branch_name" >/dev/null 2>&1
  # This is the "act() wrapper" or "fixture timestamp" type commit that must NOT be dropped
  echo "act_helper() { echo 'hand-fix'; }" > "$concurrent_dir/act-wrapper.sh"
  git -C "$concurrent_dir" add act-wrapper.sh >/dev/null 2>&1
  git -C "$concurrent_dir" commit -m "fix: add act wrapper helper (hand fix)" >/dev/null 2>&1
  git -C "$concurrent_dir" push origin "$branch_name" >/dev/null 2>&1

  # Drive the function — this triggers the rebase+push-rejection+classify+cherry-pick path
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto" "" ""

  # Must exit 2: cherry-pick preserved the code commit, re-review required for non-empty foreign content
  [ "$status" -eq 2 ]

  # CRITICAL: the foreign code commit's file must be present on the pushed branch
  [ -f "$worktree_path/act-wrapper.sh" ] || {
    echo "FAIL: act-wrapper.sh missing from worktree — foreign code commit was silently dropped"
    git -C "$worktree_path" log --oneline | head -10
    return 1
  }

  # The file must contain the expected content (not just an empty file)
  run grep -q "act_helper" "$worktree_path/act-wrapper.sh"
  [ "$status" -eq 0 ] || {
    echo "FAIL: act-wrapper.sh content missing — cherry-pick did not preserve the foreign commit's content"
    return 1
  }

  # Verify the pushed remote branch also contains the file (not just the local worktree)
  local _inspect_dir="$RITE_TEST_TMPDIR/inspect-preserve"
  git clone "$BARE_REMOTE" "$_inspect_dir" >/dev/null 2>&1
  git -C "$_inspect_dir" checkout "$branch_name" >/dev/null 2>&1
  [ -f "$_inspect_dir/act-wrapper.sh" ] || {
    echo "FAIL: act-wrapper.sh missing from pushed remote branch — cherry-pick result was not pushed"
    git -C "$_inspect_dir" log --oneline | head -10
    return 1
  }

  # Original feature work must also survive
  [ -f "$worktree_path/feature-preserve.txt" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "stale-branch push-race: TRIVIAL foreign commit with replay conflict halts loudly in auto mode (exit 1, no push)" {
  # When a TRIVIAL-classified foreign commit has code changes (non-empty content diff)
  # and the cherry-pick onto the rebased branch CONFLICTS, auto mode must halt loudly
  # without pushing — never silently discard foreign code commits.
  #
  # Fixture for cherry-pick conflict (add/add):
  #   1. Feature branch has feature.txt
  #   2. Main diverges and adds shared.txt = "main content"
  #   3. Rebase succeeds: rebased HEAD gains shared.txt from main
  #   4. Foreign commit (from pre-rebase parent, where shared.txt did NOT exist):
  #      adds shared.txt = "collaborator content"
  #   5. Cherry-pick of foreign commit onto rebased HEAD: add/add conflict on shared.txt
  #      (rebased HEAD already has it from main; foreign commit adds it again differently)
  #
  # Expected: exit 1, no force-push to remote, informative error message.

  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub classify_foreign_commits to return TRIVIAL
  classify_foreign_commits() {
    export DIVERGENCE_CLASS="TRIVIAL"
    return 0
  }

  # Stub verify_post_merge so it always passes (conflict is at cherry-pick level, not tests)
  verify_post_merge() { return 0; }

  local branch_name="fix/race-trivial-conflict-halt-27"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  # Feature branch: add feature.txt only (shared.txt does not exist yet)
  echo "feature work" > feature-halt.txt
  git add feature-halt.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main: main adds shared.txt = "main content"
  # After rebase, the worktree will have shared.txt (from main)
  git checkout main >/dev/null 2>&1
  echo "main content for shared" > shared.txt
  git add shared.txt
  git commit -m "Main: add shared.txt" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-halt-27"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Foreign commit (from concurrent client, based on feature branch tip where
  # shared.txt did NOT exist): adds shared.txt = "collaborator content".
  # After rebase, our HEAD will have shared.txt = "main content" (from main).
  # Cherry-pick this foreign commit → add/add conflict on shared.txt.
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-halt"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "collaborator@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Collaborator" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$branch_name" >/dev/null 2>&1
  # Add shared.txt differently — this conflicts on cherry-pick (main already added it)
  echo "collaborator content for shared (different from main)" > "$concurrent_dir/shared.txt"
  git -C "$concurrent_dir" add shared.txt >/dev/null 2>&1
  git -C "$concurrent_dir" commit -m "fix: add shared.txt (collaborator version)" >/dev/null 2>&1
  git -C "$concurrent_dir" push origin "$branch_name" >/dev/null 2>&1

  # Record the remote tip BEFORE the function runs (to verify no force-push happened)
  local remote_tip_before
  remote_tip_before=$(git ls-remote "$BARE_REMOTE" "refs/heads/$branch_name" | awk '{print $1}' || true)

  # Drive the function in auto mode — cherry-pick will conflict, must halt (exit 1)
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto" "" ""

  # Must return non-zero (halt, no push)
  [ "$status" -ne 0 ] || {
    echo "FAIL: function returned 0 — should have halted on cherry-pick conflict"
    return 1
  }

  # CRITICAL: the remote tip must NOT have advanced — no force-push should have occurred
  local remote_tip_after
  remote_tip_after=$(git ls-remote "$BARE_REMOTE" "refs/heads/$branch_name" | awk '{print $1}' || true)
  [ "$remote_tip_before" = "$remote_tip_after" ] || {
    echo "FAIL: remote tip changed from $remote_tip_before to $remote_tip_after"
    echo "      A force-push occurred despite a cherry-pick conflict — foreign commits may have been lost"
    return 1
  }

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}
