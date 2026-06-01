#!/usr/bin/env bats
# tests/regression/post-rollback-stale-head.bats
#
# Regression tests for issue #133: Post-rollback uses potentially stale local HEAD.
#
# The bug: when verify_post_merge fails after a successful rebase, the rollback
# previously used DIVERGENCE_LOCAL_HEAD — which is:
#   - Unset on the direct-call path (not via handle_push_divergence), silently
#     skipping the reset and leaving the working tree in the post-rebase state.
#   - Potentially stale after a resolver (issue #21) creates new commits between
#     the original local HEAD and the rebase.
#
# The fix: snapshot HEAD at the entry of _do_rebase_and_push into _pre_rebase_head
# (a local variable), and prefer it over DIVERGENCE_LOCAL_HEAD for rollback.
#
# These tests verify:
#   1. Direct-call path: rollback happens even with DIVERGENCE_LOCAL_HEAD unset.
#   2. Orchestrated path: rollback still works when DIVERGENCE_LOCAL_HEAD is set.
#   3. Resolver path: rollback targets the pre-rebase HEAD, not the post-resolver HEAD.
#   4. No-rollback-target path: warning is emitted but no crash.

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

  # Source the divergence-handler library
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────────────
# Helper: set up a clean (non-conflicting) divergence so rebase succeeds.
#
# The remote branch adds a new file (no conflict with local changes).
# After setup:
#   - BRANCH_NAME is set
#   - WORKTREE_PATH is set; cwd is WORKTREE_PATH
#   - local branch is behind origin/BRANCH_NAME by one commit (no conflict)
#   - _local_sha_before_rebase is the local HEAD before rebase (for assertions)
# ───────────────────────────────────────────────────────────────────────────
_setup_non_conflicting_divergence() {
  BRANCH_NAME="fix/rollback-test-$$"

  # Local feature commit
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -m "Feature: add feature.txt" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Remote-only commit (different file — no conflict, rebase will succeed cleanly)
  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-nc-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Test User"
  git -C "$tmp_clone" config user.email "test@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "remote addition" > "$tmp_clone/remote-only.txt"
  git -C "$tmp_clone" add remote-only.txt
  git -C "$tmp_clone" commit -m "Remote: add remote-only.txt" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1

  # Create worktree at the pre-fetch local HEAD
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-rollback-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  cd "$WORKTREE_PATH"

  # Fetch so divergence detection works
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # Capture local HEAD before rebase (for rollback assertions)
  _local_sha_before_rebase=$(git rev-parse HEAD)
}

_cleanup_branch() {
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────────────
# Test 1: Direct-call path — DIVERGENCE_LOCAL_HEAD unset, rollback must still happen
# ───────────────────────────────────────────────────────────────────────────
@test "post-rollback: direct-call path resets to pre-rebase HEAD even when DIVERGENCE_LOCAL_HEAD is unset" {
  _setup_non_conflicting_divergence

  # Ensure DIVERGENCE_LOCAL_HEAD is unset (direct-call path simulation)
  unset DIVERGENCE_LOCAL_HEAD 2>/dev/null || true

  # Stub verify_post_merge to always fail — triggers the rollback path
  verify_post_merge() { return 1; }

  # Run _do_rebase_and_push in auto mode — rebase will succeed, verify will fail, rollback should fire
  _do_rebase_and_push "$BRANCH_NAME" "true" "133" "999" 2>/dev/null || true

  # The working tree HEAD should be back to the pre-rebase local SHA
  local current_head
  current_head=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")

  [ "$current_head" = "$_local_sha_before_rebase" ]

  _cleanup_branch
}

# ───────────────────────────────────────────────────────────────────────────
# Test 2: Orchestrated path — DIVERGENCE_LOCAL_HEAD is set, rollback still uses
# _pre_rebase_head (same value, but proves the fallback chain works)
# ───────────────────────────────────────────────────────────────────────────
@test "post-rollback: orchestrated path resets to pre-rebase HEAD when DIVERGENCE_LOCAL_HEAD is set" {
  _setup_non_conflicting_divergence

  # Simulate orchestrated path: DIVERGENCE_LOCAL_HEAD is set (matches local HEAD before rebase)
  export DIVERGENCE_LOCAL_HEAD="$_local_sha_before_rebase"

  # Stub verify_post_merge to always fail
  verify_post_merge() { return 1; }

  _do_rebase_and_push "$BRANCH_NAME" "true" "133" "999" 2>/dev/null || true

  local current_head
  current_head=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")

  [ "$current_head" = "$_local_sha_before_rebase" ]

  unset DIVERGENCE_LOCAL_HEAD 2>/dev/null || true
  _cleanup_branch
}

# ───────────────────────────────────────────────────────────────────────────
# Test 3: Resolver path — resolver adds a commit, then verify fails.
#         Rollback should target the pre-rebase HEAD (before resolver committed),
#         not the post-resolver HEAD.
# ───────────────────────────────────────────────────────────────────────────
@test "post-rollback: resolver path rolls back to pre-rebase HEAD (not post-resolver HEAD)" {
  _setup_non_conflicting_divergence

  # Make the rebase itself conflict by overwriting the same line in README.md
  # from the remote side — but for simplicity we can just stub _do_rebase to
  # simulate the "rebase conflict resolved by resolver" path directly.
  # We stub _do_rebase to fail, then provide a resolver that adds a commit.

  # DIVERGENCE_LOCAL_HEAD is unset (direct-call path)
  unset DIVERGENCE_LOCAL_HEAD 2>/dev/null || true

  # Override _do_rebase to simulate a conflict (returns 1)
  _do_rebase() { return 1; }

  # Resolver stub: adds a new commit on top of current HEAD and records the new SHA.
  # This advances HEAD beyond _pre_rebase_head so the two SHAs are distinct.
  # Without this recording, the test cannot distinguish "rolled back to pre-rebase HEAD"
  # from "happened to stay at post-resolver HEAD by accident".
  _post_resolver_sha=""
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "resolver output" > resolver-output.txt
    git add resolver-output.txt
    git commit -m "chore: resolver adds commit (stub)" >/dev/null 2>&1
    _post_resolver_sha=$(git rev-parse HEAD 2>/dev/null || true)
    return 0
  }

  # Stub verify_post_merge to fail — triggers rollback after resolver succeeds
  verify_post_merge() { return 1; }

  _do_rebase_and_push "$BRANCH_NAME" "true" "133" "999" 2>/dev/null || true

  local current_head
  current_head=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")

  # Confirm the resolver actually ran and created a distinct SHA.
  # If _post_resolver_sha is empty, the resolver never ran — test setup is broken.
  [ -n "$_post_resolver_sha" ] || { echo "resolver stub never ran" >&2; return 1; }

  # The pre-rebase SHA and post-resolver SHA must differ — otherwise the test
  # proves nothing about which target the rollback chose.
  [ "$_local_sha_before_rebase" != "$_post_resolver_sha" ] \
    || { echo "post-resolver SHA equals pre-rebase SHA — resolver commit did not advance HEAD" >&2; return 1; }

  # Must be back at the pre-rebase SHA, not at the resolver-created SHA
  [ "$current_head" = "$_local_sha_before_rebase" ]
  [ "$current_head" != "$_post_resolver_sha" ]

  _cleanup_branch
}

# ───────────────────────────────────────────────────────────────────────────
# Test 4: No rollback target available — warning emitted, no crash, returns non-zero
# ───────────────────────────────────────────────────────────────────────────
@test "post-rollback: emits warning (not crash) when no rollback target available" {
  _setup_non_conflicting_divergence

  # Make git rev-parse fail by pointing to an invalid git environment.
  # We simulate this by making _pre_rebase_head unavailable — we can't unset
  # a local variable from outside a function, so instead we override _do_rebase_and_push
  # to test the warning path via a minimal wrapper that proves the guard fires.
  #
  # Strategy: stub git rev-parse to return empty, stub _do_rebase to succeed,
  # stub verify_post_merge to fail. The rollback block should emit a warning
  # and NOT crash with a non-zero unexpected exit.
  unset DIVERGENCE_LOCAL_HEAD 2>/dev/null || true

  # Override git so that rev-parse returns empty (simulates git failure at entry)
  git() {
    if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
      echo ""
      return 0
    fi
    command git "$@"
  }

  # _do_rebase succeeds (no conflict)
  _do_rebase() { return 0; }

  # verify_post_merge fails — triggers rollback block
  verify_post_merge() { return 1; }

  # Single invocation: capture both stderr (warning) and exit code.
  # Two separate calls would share residual worktree state from the first run
  # and cannot be treated as independent observations.
  local output exit_code=0
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "133" "999" 2>&1) || exit_code=$?

  # Should emit the "no rollback target" warning, not crash with unbound variable
  echo "$output" | grep -qi "no rollback target"

  # Function should return non-zero (auto mode blocks on verify failure)
  [ "$exit_code" -ne 0 ]

  unset -f git 2>/dev/null || true
  _cleanup_branch
}
