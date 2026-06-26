#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh
# tests/regression/stale-branch-dirty-worktree.bats - Dirty worktree stash/restore tests
#
# Tests that _stale_rebase_onto_main correctly stashes uncommitted changes before
# rebasing and restores them after. Also covers the --force-with-lease rejection
# safety property: when a concurrent push updates the remote between rebase and
# force-push, the push must be rejected.
#
# Covers gaps from issue #87 (follow-up from PR #86 assessment).

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

  # Source the stale-branch library (also pulls in stash-manager, post-merge-verify)
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# Dirty worktree stash/restore — tracked file changes
# =============================================================================

@test "dirty worktree - tracked changes preserved across rebase" {
  # Test: Feature branch has a committed change, plus an uncommitted modification
  #       to a tracked file. Rebase onto diverged main should:
  #         1. Stash the uncommitted change before rebasing
  #         2. Rebase successfully
  #         3. Restore (pop) the stash after rebasing
  #         4. Leave the working tree dirty with the original uncommitted change

  local branch_name="fix/dirty-tracked-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1

  # Committed feature work
  echo "committed feature" > feature.txt
  git add feature.txt
  git commit -m "Feature commit" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree on the feature branch (fixture repo must NOT have the
  # branch checked out, or `git worktree add` errors with 'already checked out')
  git checkout main >/dev/null 2>&1
  local worktree_path="$RITE_WORKTREE_DIR/issue-dirty-tracked"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Dirty the worktree: modify the tracked file without committing
  echo "uncommitted modification" >> "$worktree_path/feature.txt"

  # Verify the worktree is dirty before the rebase
  run git -C "$worktree_path" diff --quiet
  [ "$status" -ne 0 ]  # non-zero = dirty

  # Diverge main while the worktree stays dirty
  git checkout main >/dev/null 2>&1
  echo "main addition" > main-only.txt
  git add main-only.txt
  git commit -m "Main divergence" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Run rebase — must succeed despite dirty worktree
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  # Main's new file must be present (rebase worked)
  [ -f "$worktree_path/main-only.txt" ]

  # Feature commit must still exist
  [ -f "$worktree_path/feature.txt" ]

  # Working tree must still be dirty — the uncommitted modification was restored
  run git -C "$worktree_path" diff --quiet
  [ "$status" -ne 0 ]  # non-zero = still dirty

  # The content of the modification must match exactly what was stashed
  local content
  content=$(cat "$worktree_path/feature.txt")
  [[ "$content" == *"uncommitted modification"* ]]

  # No sharkrite stash should remain (stash was popped)
  local stash_count
  stash_count=$(git -C "$worktree_path" stash list | grep -c "\[sharkrite-managed-stash\]" || true)
  [ "$stash_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

# =============================================================================
# Dirty worktree stash/restore — staged changes
# =============================================================================

@test "dirty worktree - staged (index) changes preserved across rebase" {
  # Test: Feature branch has uncommitted changes that are staged (git add but no commit).
  #       _stale_rebase_onto_main checks BOTH `git diff --quiet` (unstaged) AND
  #       `git diff --cached --quiet` (staged). Staged changes must also be stashed
  #       and restored.

  local branch_name="fix/dirty-staged-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1

  # Committed feature work
  echo "initial feature" > staged-feature.txt
  git add staged-feature.txt
  git commit -m "Initial feature commit" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree (fixture repo must be off the feature branch first)
  git checkout main >/dev/null 2>&1
  local worktree_path="$RITE_WORKTREE_DIR/issue-dirty-staged"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Stage a change — add to index but don't commit
  echo "staged but not committed" > "$worktree_path/staged-work.txt"
  git -C "$worktree_path" add staged-work.txt >/dev/null 2>&1

  # Verify the index is dirty (staged changes present)
  run git -C "$worktree_path" diff --cached --quiet
  [ "$status" -ne 0 ]  # non-zero = staged changes

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main work" > main-staged-test.txt
  git add main-staged-test.txt
  git commit -m "Main divergence" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Run rebase — must succeed despite staged changes
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  # Main's new file must be present
  [ -f "$worktree_path/main-staged-test.txt" ]

  # The staged file must be restored to the working tree
  [ -f "$worktree_path/staged-work.txt" ]
  local content
  content=$(cat "$worktree_path/staged-work.txt")
  [ "$content" = "staged but not committed" ]

  # No sharkrite stash should remain
  local stash_count
  stash_count=$(git -C "$worktree_path" stash list | grep -c "\[sharkrite-managed-stash\]" || true)
  [ "$stash_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

# =============================================================================
# Dirty worktree stash/restore — rebase conflict path
# =============================================================================

@test "dirty worktree - stash restored when rebase has conflicts and aborts" {
  # Test: Rebase fails due to conflicts (both feature branch and main modify the same file).
  #       The function must:
  #         1. Stash the dirty worktree before attempting rebase
  #         2. Detect the conflict, abort the rebase cleanly
  #         3. Pop the stash — leaving the worktree dirty again as it was before
  #       If the stash is NOT restored, the uncommitted change is permanently lost.
  #
  # Stub attempt_claude_merge_resolution to return 1 so this test deterministically
  # exercises the plain auto-bail path (print_error + return 1) rather than
  # potentially flowing through the Claude-assisted conflict resolver.  Without the
  # stub, if conflict-resolver.sh is sourced and attempt_claude_merge_resolution is
  # defined in the environment, the test could attempt a provider call or resolve
  # the conflict and return 0 — changing the expected exit code and making the test
  # environment-dependent / flaky.
  attempt_claude_merge_resolution() { return 1; }

  local branch_name="fix/dirty-conflict-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1

  # Committed feature change (modifies shared.txt)
  echo "feature version" > shared.txt
  git add shared.txt
  git commit -m "Feature modifies shared.txt" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree (fixture repo must be off the feature branch first)
  git checkout main >/dev/null 2>&1
  local worktree_path="$RITE_WORKTREE_DIR/issue-dirty-conflict"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Dirty the worktree with a local modification
  echo "local in-progress work" > "$worktree_path/in-progress.txt"

  # Main also modifies shared.txt — will cause a rebase conflict
  git checkout main >/dev/null 2>&1
  echo "main version (conflicts with feature)" > shared.txt
  git add shared.txt
  git commit -m "Main modifies shared.txt" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Run rebase — should fail due to conflict. Use `run` so the expected non-zero
  # return is captured in $status rather than tripping bats' errexit on the bare
  # command (the auto-mode conflict bail returns 1 from stale-branch.sh).
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"

  # Must return non-zero (rebase conflict path)
  [ "$status" -ne 0 ]

  # No leftover rebase state (abort was clean)
  [ ! -d "$worktree_path/.git/rebase-merge" ]
  [ ! -d "$worktree_path/.git/rebase-apply" ]

  # The uncommitted file must be restored (stash was popped after abort)
  [ -f "$worktree_path/in-progress.txt" ]
  local content
  content=$(cat "$worktree_path/in-progress.txt")
  [ "$content" = "local in-progress work" ]

  # No sharkrite stash should remain after restore
  local stash_count
  stash_count=$(git -C "$worktree_path" stash list | grep -c "\[sharkrite-managed-stash\]" || true)
  [ "$stash_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

# =============================================================================
# force-with-lease rejection semantics
# =============================================================================

@test "force-with-lease rejected when remote is updated concurrently" {
  # Test: The safety property of --force-with-lease, exercised through
  #       _stale_rebase_onto_main (the actual function under test).
  #
  # Scenario:
  #   1. Feature branch is pushed to origin.
  #   2. A concurrent client pushes a new commit to the same remote branch,
  #      advancing the remote tip.
  #   3. The worktree's tracking ref is NOT updated (no fetch) — it still
  #      points to the original SHA our branch was pushed at.
  #   4. main diverges, so _stale_rebase_onto_main will attempt a rebase+push.
  #   5. _stale_rebase_onto_main calls `git push --force-with-lease`.
  #      The lease check compares the local tracking ref (original SHA) against
  #      the actual remote tip (concurrent SHA) — they differ → push rejected.
  #   6. The rejection routes into _stale_classify_after_push_rejection. In auto
  #      mode the foreign (concurrent) commit is classified UNRELATED, INTEGRATED
  #      (rebased onto origin/<branch>) and re-pushed with --force-with-lease, so
  #      the function returns 2 (re-enter Phase 2→3 for review). The remote tip is
  #      rewritten to a combined history that still CONTAINS the concurrent commit
  #      (integrated, not overwritten/lost).
  #
  # Without --force-with-lease (plain --force), the concurrent push would be
  # silently overwritten. Catching a regression to --force is the entire point
  # of this test.

  # Force a deterministic UNRELATED classification without a real Claude call —
  # otherwise this test makes an unstubbed provider_run_classify network call.
  classify_foreign_commits() { export DIVERGENCE_CLASS="UNRELATED"; return 0; }

  local branch_name="fix/force-lease-reject-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature-lease.txt
  git add feature-lease.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Record the original remote SHA — this is what the worktree's tracking ref
  # will point to after the concurrent push (because we never fetch).
  local original_remote_sha
  original_remote_sha=$(git rev-parse "origin/$branch_name")

  # Simulate a concurrent push NOW — before main diverges and before the worktree
  # is created. The worktree will be created from the local branch which still has
  # the old tracking ref, so --force-with-lease will see the mismatch.
  local concurrent_work_dir="$RITE_TEST_TMPDIR/concurrent-client"
  git clone "$BARE_REMOTE" "$concurrent_work_dir" >/dev/null 2>&1
  git -C "$concurrent_work_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_work_dir" config user.name "Concurrent" >/dev/null 2>&1
  git -C "$concurrent_work_dir" checkout "$branch_name" >/dev/null 2>&1
  echo "concurrent change" > "$concurrent_work_dir/concurrent.txt"
  git -C "$concurrent_work_dir" add concurrent.txt >/dev/null 2>&1
  git -C "$concurrent_work_dir" commit -m "Concurrent commit (simulates racing push)" >/dev/null 2>&1
  git -C "$concurrent_work_dir" push origin "$branch_name" >/dev/null 2>&1

  # Verify concurrent push landed (sanity check before proceeding)
  local concurrent_remote_sha
  concurrent_remote_sha=$(git ls-remote "$BARE_REMOTE" "refs/heads/$branch_name" | awk '{print $1}' || true)
  [ "$original_remote_sha" != "$concurrent_remote_sha" ]

  # Diverge main so _stale_rebase_onto_main has work to do
  git checkout main >/dev/null 2>&1
  echo "main work" > main-lease.txt
  git add main-lease.txt
  git commit -m "Main divergence" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree from the local feature branch (tracking ref still points to
  # original_remote_sha — the worktree inherits the main repo's stale ref)
  local worktree_path="$RITE_WORKTREE_DIR/issue-force-lease-reject"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Record the pre-rebase HEAD so we can confirm the rebase actually ran.
  local pre_rebase_head
  pre_rebase_head=$(git -C "$worktree_path" rev-parse HEAD)

  # Drive the rebase+push through the actual function under test.
  # _stale_rebase_onto_main will:
  #   1. Rebase the feature branch onto origin/main (rewrites history)
  #   2. Attempt git push --force-with-lease origin <branch>
  #   3. Lease fails: local tracking ref = original_remote_sha,
  #      remote tip = concurrent_remote_sha → git rejects the push
  #   4. Rejection routes into _stale_classify_after_push_rejection; auto mode
  #      classifies UNRELATED, integrates the foreign commit and re-pushes,
  #      returning 2 (re-enter Phase 2→3 for review)
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"

  # Confirm the rebase step actually ran before the push attempt:
  #   - HEAD must have changed (rebase rewrote history onto origin/main)
  #   - main-lease.txt must be present (main's divergence commit was applied)
  # Without these assertions, a failure in an earlier phase (e.g. rebase itself
  # returning non-zero) would produce the same non-zero exit and mask the real
  # failure cause, making the test pass for the wrong reason.
  local post_rebase_head
  post_rebase_head=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$pre_rebase_head" != "$post_rebase_head" ]  # rebase rewrote HEAD
  [ -f "$worktree_path/main-lease.txt" ]           # main's commit was applied

  # force-with-lease was rejected; auto mode integrated the foreign commit and
  # re-pushed → exit 2 (re-enter Phase 2→3 for review), tip is rewritten.
  [ "$status" -eq 2 ]

  # The concurrent commit must still be REACHABLE on the remote (integrated, not lost)
  git fetch "$BARE_REMOTE" "refs/heads/$branch_name" >/dev/null 2>&1
  run git merge-base --is-ancestor "$concurrent_remote_sha" FETCH_HEAD
  [ "$status" -eq 0 ]   # concurrent commit is an ancestor of the new remote tip

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

# =============================================================================
# Clean worktree guard — stash path is NOT taken for clean trees
# =============================================================================

@test "clean worktree - no stash created during rebase" {
  # Regression guard: When the worktree is clean, _stale_rebase_onto_main must
  # NOT create any stash (the _stashed=false branch). This prevents spurious
  # stash entries in repos where users track their own stash stack.

  local branch_name="fix/clean-no-stash-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > clean-feature.txt
  git add clean-feature.txt
  git commit -m "Feature commit" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree — clean state (fixture repo must be off the feature branch first)
  git checkout main >/dev/null 2>&1
  local worktree_path="$RITE_WORKTREE_DIR/issue-clean-no-stash"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Confirm clean worktree
  run git -C "$worktree_path" diff --quiet
  [ "$status" -eq 0 ]
  run git -C "$worktree_path" diff --cached --quiet
  [ "$status" -eq 0 ]

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main work" > main-clean.txt
  git add main-clean.txt
  git commit -m "Main divergence" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # No stashes before rebase
  local stash_before
  stash_before=$(git -C "$worktree_path" stash list | wc -l | tr -d ' ')

  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  # Still no stashes after rebase — clean path creates none
  local stash_after
  stash_after=$(git -C "$worktree_path" stash list | wc -l | tr -d ' ')
  [ "$stash_before" -eq "$stash_after" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}
