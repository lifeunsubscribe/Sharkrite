#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/divergence-handler.sh
# tests/regression/divergence-handler-reset-failure.bats
#
# Tests the supervised fall-through behaviour when git reset --hard fails
# after post-rebase verification (verify_post_merge) reports test failures.
#
# Background (PR #184 assessment):
#   When verify_post_merge fails, the handler rolls back via git reset --hard.
#   If that rollback itself fails, the working tree remains in post-rebase state.
#   Previously, the supervised path would then offer "c) Force-push local work",
#   which was misleading: it would push the broken post-rebase state, not the
#   original pre-rebase work.
#
#   Fix: track whether rollback succeeded (_rollback_succeeded flag). If rollback
#   failed in supervised mode, abort with a clear diagnostic rather than presenting
#   options that imply the working tree is in the expected state.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"
  export RITE_SKIP_TESTS=true  # Skip actual test suite in verify_post_merge

  mkdir -p "$RITE_WORKTREE_DIR"
  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ─────────────────────────────────────────────────────────────────────────
# Shared helper: set up a clean fast-forward divergence (no real conflict).
#
# Local is behind origin (origin has one extra commit). Rebase succeeds
# cleanly. We then stub verify_post_merge to simulate test failures.
# ─────────────────────────────────────────────────────────────────────────
_setup_fast_forward_divergence() {
  BRANCH_NAME="fix/reset-fail-test-$$"

  # Feature branch: push to origin so it tracks
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "# Feature work" > feature.txt
  git add feature.txt
  git commit -m "Feature: initial work" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Remote: add a non-conflicting commit (different file) — rebase will succeed
  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Test User"
  git -C "$tmp_clone" config user.email "test@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "remote-only fix" > "$tmp_clone/remote-fix.txt"
  git -C "$tmp_clone" add remote-fix.txt
  git -C "$tmp_clone" commit -m "Remote: non-conflicting fix" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1

  # Switch main repo to 'main' so worktree add can check out $BRANCH_NAME
  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-reset-fail-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
  cd "$WORKTREE_PATH"
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # Sanity: this rebase must succeed (no conflict) so we can test the
  # rollback-failure path (not the conflict path).
  # Attempt the rebase, then reset to the branch head if it succeeds.
  local _sanity_head
  _sanity_head=$(git rev-parse HEAD 2>/dev/null || true)
  if ! git rebase "origin/$BRANCH_NAME" >/dev/null 2>&1; then
    echo "ERROR: fixture setup produced a conflict — expected clean fast-forward" >&2
    git rebase --abort 2>/dev/null || true
    return 1
  fi
  # Rebase succeeded — reset back to original HEAD so the real test can drive the flow
  git reset --hard "$_sanity_head" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────
# Test 1: reset --hard failure in supervised mode → abort with diagnostic
#
# When verify_post_merge fails AND git reset --hard fails, the supervised
# path must NOT present "c) Force-push local work". Instead it must abort
# with a clear diagnostic explaining the rollback failed.
# ─────────────────────────────────────────────────────────────────────────
@test "divergence: supervised mode aborts when rollback fails after post-rebase test failure" {
  _setup_fast_forward_divergence

  # Stub verify_post_merge to simulate test failures after the rebase
  verify_post_merge() { return 1; }

  # Override git reset to fail only on --hard invocations (simulates locked index, etc.)
  # We need to intercept git calls. Use a wrapper function that delegates to real git
  # except for 'reset --hard'.
  _real_git="$(command -v git)"
  git() {
    if [[ "$1" == "reset" && "$2" == "--hard" ]]; then
      echo "error: Could not reset index file to revision." >&2
      return 1
    fi
    "$_real_git" "$@"
  }
  export -f git

  # Run in supervised mode (not auto). Use REPLY=d to select "Abort" — but we expect
  # the function to abort BEFORE presenting any menu when rollback fails.
  # Feed 'd' via stdin in case the menu IS (incorrectly) shown.
  local exit_code=0
  local output
  output=$(echo "d" | _do_rebase_and_push "$BRANCH_NAME" "false" "129" "200" 2>&1) || exit_code=$?

  # Unset git override before assertions (cleanup)
  unset -f git

  # Must fail (exit non-zero)
  [ "$exit_code" -ne 0 ]

  # Must print the clear diagnostic about rollback failure
  echo "$output" | grep -qi "Cannot recover automatically\|rollback.*failed\|post-rebase state"

  # Must print the manual recovery instructions (git reset --hard command)
  echo "$output" | grep -q "git reset --hard"

  # Must NOT present the interactive "Force-push" menu — that option would push
  # the broken post-rebase state and is misleading when rollback failed.
  ! echo "$output" | grep -qi "Force-push local.*pre-rebase\|Force-push local work"

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────
# Test 2: successful rollback in supervised mode → presents correct options
#
# When verify_post_merge fails but git reset --hard succeeds, the supervised
# path should present the recovery menu. Option "c" should describe the state
# accurately: "pre-rebase work" (not "local work" which was ambiguous).
# ─────────────────────────────────────────────────────────────────────────
@test "divergence: supervised mode offers force-push menu when rollback succeeds" {
  _setup_fast_forward_divergence

  # Stub verify_post_merge to simulate test failures after the rebase.
  # git reset --hard is NOT overridden — it will succeed.
  verify_post_merge() { return 1; }

  # Feed 'd' (abort) via stdin — we're testing that the menu IS presented,
  # not that the force-push succeeds.
  local exit_code=0
  local output
  output=$(echo "d" | _do_rebase_and_push "$BRANCH_NAME" "false" "129" "200" 2>&1) || exit_code=$?

  # Menu was presented → user chose 'd' → exit non-zero (abort)
  [ "$exit_code" -ne 0 ]

  # Option "c" label should clearly say "pre-rebase" to be accurate
  echo "$output" | grep -qi "pre-rebase"

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────
# Test 3: auto mode still blocks when rollback fails (no regression)
#
# In auto mode, the rollback-failure path was already correct (returns 1).
# This test ensures the new _rollback_succeeded tracking didn't break
# the auto mode path.
# ─────────────────────────────────────────────────────────────────────────
@test "divergence: auto mode blocks regardless of rollback success/failure" {
  _setup_fast_forward_divergence

  # Stub verify_post_merge to fail
  verify_post_merge() { return 1; }

  # Override git reset to fail (worst case)
  _real_git="$(command -v git)"
  git() {
    if [[ "$1" == "reset" && "$2" == "--hard" ]]; then
      echo "error: Could not reset index file to revision." >&2
      return 1
    fi
    "$_real_git" "$@"
  }
  export -f git

  local exit_code=0
  local output
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "129" "200" 2>&1) || exit_code=$?

  unset -f git

  # Auto mode must still block (exit non-zero)
  [ "$exit_code" -ne 0 ]

  # Should print the blocking message
  echo "$output" | grep -qi "Post-rebase verification failed\|blocking in auto mode"

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}
