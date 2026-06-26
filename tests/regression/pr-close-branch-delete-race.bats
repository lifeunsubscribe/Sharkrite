#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh, lib/core/workflow-runner.sh
# tests/regression/pr-close-branch-delete-race.bats
#
# Regression tests for the race condition between PR close and remote branch deletion.
#
# The bug: when `gh pr close` fails but the branch delete is allowed to proceed anyway,
# GitHub is left in an inconsistent state — an open PR pointing to a deleted branch.
# The fix: remote branch deletion is gated on PR close success in both:
#   - lib/utils/stale-branch.sh (_stale_close_and_cleanup)
#   - lib/utils/branch-preflight.sh (preflight_auto_recover_empty)
#
# These tests stub `gh` to simulate API failures and verify the gate holds.
#
# Verifies fix for issue #89 (Handle race condition in PR close/branch deletion)

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

  # Track git push --delete calls via a flag file
  export GH_PUSH_DELETE_FLAG="${RITE_TEST_TMPDIR}/push_delete_called"
  export GH_PR_CLOSE_FLAG="${RITE_TEST_TMPDIR}/pr_close_called"
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────
# Helper: create a stale branch + worktree with ONLY an init commit
# Sets BRANCH_NAME and WORKTREE_PATH in caller's scope.
# ───────────────────────────────────────────────────────────────────
_setup_stale_empty_branch() {
  local issue_number="${1:-77}"
  BRANCH_NAME="fix/race-test-issue-${issue_number}"

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #${issue_number}" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-${issue_number}"

  git checkout main >/dev/null 2>&1
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────
# stale-branch.sh: _stale_close_and_cleanup
# ───────────────────────────────────────────────────────────────────

@test "stale-branch: PR close fails → remote branch is NOT deleted (race guard)" {
  # Test: When gh pr close fails with a non-recoverable error, the remote branch
  # must NOT be deleted. Deleting the branch with an open PR leaves GitHub in an
  # inconsistent state where the PR page shows "branch deleted" for an open PR.

  _setup_stale_empty_branch 77

  # Source library (must be after fixture setup so RITE_LIB_DIR is exported)
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub gh to fail pr close with a generic error (not "already closed")
  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "close" ]; then
      echo "pr_close_called" > "$GH_PR_CLOSE_FLAG"
      echo "GraphQL: Something went wrong" >&2
      return 1
    fi
    # Let pr comment and other commands fail silently
    return 0
  }
  export -f gh

  # Run cleanup with a fake PR number
  _stale_close_and_cleanup "999" "77" "$WORKTREE_PATH" "$BRANCH_NAME" "15" 2>/dev/null || true

  # PR close was attempted
  [ -f "$GH_PR_CLOSE_FLAG" ]

  # Remote branch must still exist (was NOT deleted due to gate)
  git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"

  # Local worktree was still removed (local cleanup is safe regardless)
  [ ! -d "$WORKTREE_PATH" ]
}

@test "stale-branch: PR close succeeds → remote branch IS deleted" {
  # Test: When PR close succeeds, remote branch deletion proceeds normally.

  _setup_stale_empty_branch 78

  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub gh to succeed for pr close
  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "close" ]; then
      echo "pr_close_called" > "$GH_PR_CLOSE_FLAG"
      return 0
    fi
    # pr comment — succeed silently
    return 0
  }
  export -f gh

  _stale_close_and_cleanup "998" "78" "$WORKTREE_PATH" "$BRANCH_NAME" "12" 2>/dev/null || true

  # PR close was called
  [ -f "$GH_PR_CLOSE_FLAG" ]

  # Remote branch should be gone
  ! git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"
}

@test "stale-branch: PR already closed → treated as success, branch deleted" {
  # Test: If gh pr close returns the "already closed" message, the gate treats
  # it as a success (idempotent) and proceeds with branch deletion.

  _setup_stale_empty_branch 79

  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  # Stub: simulate "already closed" response from gh
  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "close" ]; then
      echo "already closed" >&2
      return 1
    fi
    return 0
  }
  export -f gh

  _stale_close_and_cleanup "997" "79" "$WORKTREE_PATH" "$BRANCH_NAME" "20" 2>/dev/null || true

  # Remote branch should be gone (idempotent path treated as success)
  ! git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"
}

# ───────────────────────────────────────────────────────────────────
# branch-preflight.sh: preflight_auto_recover_empty
# ───────────────────────────────────────────────────────────────────

@test "preflight: PR close fails → remote branch is NOT deleted (race guard)" {
  # Test: preflight_auto_recover_empty must also guard against deleting the remote
  # branch when PR close fails.

  _setup_stale_empty_branch 80

  source "$RITE_LIB_DIR/utils/branch-preflight.sh"

  # Stub gh to fail pr close
  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "close" ]; then
      echo "pr_close_called" > "$GH_PR_CLOSE_FLAG"
      echo "GraphQL: Something went wrong" >&2
      return 1
    fi
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
      # Simulate a valid draft PR with 0 additions
      echo "true,OPEN"
      return 0
    fi
    return 0
  }
  export -f gh

  # Override paste to return the expected format
  paste() {
    echo "true,OPEN"
  }
  export -f paste

  preflight_auto_recover_empty "80" "$BRANCH_NAME" "$WORKTREE_PATH" "996" 2>/dev/null || true

  # PR close was attempted
  [ -f "$GH_PR_CLOSE_FLAG" ]

  # Remote branch must still exist
  git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"

  # Local worktree was still removed
  [ ! -d "$WORKTREE_PATH" ]
}

@test "preflight: no PR → remote branch deleted unconditionally" {
  # Test: When there is no PR (pr_number is empty), branch deletion proceeds
  # without needing to gate on PR close (there's nothing to close).

  _setup_stale_empty_branch 81

  source "$RITE_LIB_DIR/utils/branch-preflight.sh"

  # Stub gh — should NOT be called for pr close
  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "close" ]; then
      echo "unexpected_pr_close_called" > "$GH_PR_CLOSE_FLAG"
      return 1
    fi
    return 1  # All gh calls fail (no gh auth in test env)
  }
  export -f gh

  # Call with empty pr_number
  preflight_auto_recover_empty "81" "$BRANCH_NAME" "$WORKTREE_PATH" "" 2>/dev/null || true

  # PR close should NOT have been called
  [ ! -f "$GH_PR_CLOSE_FLAG" ]

  # Remote branch deleted (no PR means it's safe)
  ! git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"
}

@test "preflight: PR already CLOSED → branch deleted (idempotent)" {
  # Test: If gh pr view reports the PR is already CLOSED, treat as already resolved
  # and proceed with branch deletion without attempting to close again.

  _setup_stale_empty_branch 82

  source "$RITE_LIB_DIR/utils/branch-preflight.sh"

  # Stub gh: PR view returns CLOSED state, pr close should not be called
  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
      if echo "$@" | grep -q "isDraft,state"; then
        echo "false,CLOSED"
        return 0
      fi
    fi
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "close" ]; then
      echo "unexpected_pr_close_called" > "$GH_PR_CLOSE_FLAG"
      return 1
    fi
    return 0
  }
  export -f gh

  paste() {
    echo "false,CLOSED"
  }
  export -f paste

  preflight_auto_recover_empty "82" "$BRANCH_NAME" "$WORKTREE_PATH" "994" 2>/dev/null || true

  # PR close should NOT have been called (already CLOSED)
  [ ! -f "$GH_PR_CLOSE_FLAG" ]

  # Remote branch should be gone
  ! git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"
}
