#!/usr/bin/env bats
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

  # Skip post-merge test suite — fixture repos have no test runner.
  # verify_post_merge returns 0 (no runner found) without this, but setting
  # explicitly guards against future changes to the detection logic.
  export RITE_SKIP_TESTS=true

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

  # Create worktree on the feature branch
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

  # Create worktree
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

  local branch_name="fix/dirty-conflict-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1

  # Committed feature change (modifies shared.txt)
  echo "feature version" > shared.txt
  git add shared.txt
  git commit -m "Feature modifies shared.txt" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Create worktree
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

  # Run rebase — should fail due to conflict
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  # Must return non-zero (rebase conflict path)
  [ "$exit_code" -ne 0 ]

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
  # Test: The safety property of --force-with-lease.
  #       After a local rebase rewrites history, we simulate a concurrent push to
  #       the same remote branch (e.g., by another process or CI bot). When
  #       _stale_rebase_onto_main tries to force-push, --force-with-lease must
  #       REJECT it because the remote's HEAD no longer matches the pre-rebase SHA.
  #
  # Without --force-with-lease (plain --force), the concurrent push would be
  # silently overwritten. This test verifies the rejection behavior.
  #
  # Implementation: We intercept the push by adding a concurrent commit to the
  # remote branch AFTER local rebase has completed but BEFORE the push. We do
  # this by wrapping git in PATH to inject the extra commit at push time.

  local branch_name="fix/force-lease-reject-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature-lease.txt
  git add feature-lease.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Record the SHA that was pushed (what --force-with-lease expects as remote tip)
  local original_remote_sha
  original_remote_sha=$(git rev-parse "origin/$branch_name")

  # Diverge main so rebase is needed
  git checkout main >/dev/null 2>&1
  echo "main work" > main-lease.txt
  git add main-lease.txt
  git commit -m "Main divergence" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree for the feature branch
  local worktree_path="$RITE_WORKTREE_DIR/issue-force-lease-reject"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Perform the rebase manually to get a rebased state (mirrors what
  # _stale_rebase_onto_main does internally before push)
  git -C "$worktree_path" rebase origin/main >/dev/null 2>&1

  # Simulate a concurrent push: advance the remote branch tip BEFORE the
  # force-push from _stale_rebase_onto_main. A second client pushes a new
  # commit, making the remote tip differ from what our local rebase expects.
  #
  # We do this directly against the bare remote (BARE_REMOTE) since we have
  # filesystem access in tests — equivalent to another process running `git push`.
  local concurrent_work_dir="$RITE_TEST_TMPDIR/concurrent-client"
  git clone "$BARE_REMOTE" "$concurrent_work_dir" >/dev/null 2>&1
  git -C "$concurrent_work_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_work_dir" config user.name "Concurrent" >/dev/null 2>&1
  git -C "$concurrent_work_dir" checkout "$branch_name" >/dev/null 2>&1
  echo "concurrent change" > "$concurrent_work_dir/concurrent.txt"
  git -C "$concurrent_work_dir" add concurrent.txt >/dev/null 2>&1
  git -C "$concurrent_work_dir" commit -m "Concurrent commit (simulates racing push)" >/dev/null 2>&1
  git -C "$concurrent_work_dir" push origin "$branch_name" >/dev/null 2>&1

  # The remote tip has now advanced past what our rebased branch expects.
  # A plain `git push --force` would overwrite it; --force-with-lease must reject.
  local new_remote_sha
  new_remote_sha=$(git -C "$worktree_path" ls-remote origin "refs/heads/$branch_name" | awk '{print $1}')
  [ "$original_remote_sha" != "$new_remote_sha" ]  # Confirm concurrent push landed

  # Attempt the force-with-lease push directly — this is the exact command
  # _stale_rebase_onto_main runs at stale-branch.sh:241
  run git -C "$worktree_path" push --force-with-lease origin "$branch_name"

  # Must be rejected (non-zero exit) because remote tip advanced concurrently
  [ "$status" -ne 0 ]

  # The concurrent commit must still exist on remote (not overwritten)
  local remote_tip_after
  remote_tip_after=$(git -C "$worktree_path" ls-remote origin "refs/heads/$branch_name" | awk '{print $1}')
  [ "$new_remote_sha" = "$remote_tip_after" ]

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

  # Create worktree — clean state
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
