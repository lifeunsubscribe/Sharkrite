#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh, lib/utils/conflict-resolver.sh
# tests/regression/stale-branch-conflict-resolver.bats
#
# Tests that stale-branch conflict bail paths invoke attempt_claude_merge_resolution
# and handle all three documented exit codes correctly:
#
#   0 = resolved — continue workflow (push and return 0)
#   1 = failure  — fall back to supervised-mode message, return 1
#   5 = usage cap — propagate exit 5 out (do NOT fall back to supervised)
#
# The tests stub attempt_claude_merge_resolution as a shell function so they
# work independently of conflict-resolver.sh landing (issue #21).
#
# Verifies fix for issue #75: Wire conflict resolver into stale-branch failures.

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

  # Source the stale-branch library (conflict-resolver.sh may not exist yet — that's fine)
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────
# Shared helper: create a conflicting branch + worktree.
#
# Sets WORKTREE_PATH and BRANCH_NAME in the caller's scope.
# After this call, the branch has a README.md conflict with origin/main.
# ───────────────────────────────────────────────────────────────────
_setup_conflicting_branch() {
  BRANCH_NAME="fix/conflict-test-$$"

  # Feature branch modifies README.md
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "Feature line" >> README.md
  git add README.md
  git commit -m "Feature changes README" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # main also modifies README.md (produces rebase conflict)
  git checkout main >/dev/null 2>&1
  echo "Main line (conflict)" >> README.md
  git add README.md
  git commit -m "Main changes README" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree from the feature branch
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-conflict-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────
# Test 1: Resolver returns 0 (resolved) → workflow continues
# ───────────────────────────────────────────────────────────────────
@test "conflict resolver exit 0: resolver returns 0, push path executes" {
  _setup_conflicting_branch

  # Stub: resolver "resolves" by creating a valid commit on the branch.
  #
  # Timing note: _stale_rebase_onto_main calls `git rebase --abort` BEFORE invoking
  # this resolver. The stub therefore runs on the post-abort HEAD (the original
  # feature branch tip, with no rebase in progress). The stub adds a commit here
  # to satisfy the production code's expectation that the resolver leaves a
  # pushable commit — it does NOT represent a commit produced by completing a real
  # rebase sequence.
  #
  # What this stub cannot model: a real resolver (issue #21) would re-run
  # `git rebase origin/main`, apply conflict resolutions, and produce a commit
  # whose parent is origin/main. The stub's commit is simply appended to the
  # pre-rebase branch tip, so git topology is fixture-dependent (origin/main
  # is always an ancestor because the branch was created from it).
  attempt_claude_merge_resolution() {
    local branch="$1"
    # Simulate Claude resolving: write a clean merged README and commit it
    cd "$WORKTREE_PATH" || return 1
    echo "Feature line" > README.md
    echo "Main line (conflict)" >> README.md
    git add README.md
    git commit -m "chore: resolve rebase conflict (stub)" >/dev/null 2>&1
    return 0
  }

  # Run rebase — should call resolver and succeed
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "75" "101"
  local exit_code=$?

  # Should succeed (exit 0 = continue workflow)
  [ "$exit_code" -eq 0 ]

  # Verify the branch was pushed (remote matches local HEAD after resolution).
  # This is the meaningful assertion this stub can make: the push path executed.
  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null)
  [ "$remote_sha" = "$local_sha" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 2: Resolver returns 1 (cannot resolve) → falls back to auto bail
# ───────────────────────────────────────────────────────────────────
@test "conflict resolver exit 1: resolver fails, auto mode prints supervised message" {
  _setup_conflicting_branch

  # Stub: resolver fails (conflicts too complex)
  attempt_claude_merge_resolution() {
    return 1
  }

  # Capture stderr for message assertions
  # Note: use || exit_code=$? pattern to capture non-zero exit codes; plain || true + $? always gives 0.
  local output exit_code=0
  output=$(_stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "75" "101" 2>&1) || exit_code=$?

  # Should return non-zero (auto mode bail)
  [ "$exit_code" -ne 0 ]

  # Should mention supervised mode (the fallback message)
  echo "$output" | grep -qi "supervised"

  # Should NOT have propagated exit 5
  [ "$exit_code" -ne 5 ]

  # Verify rebase was aborted (no leftover rebase state)
  [ ! -d "$WORKTREE_PATH/.git/rebase-merge" ]
  [ ! -d "$WORKTREE_PATH/.git/rebase-apply" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 3: Resolver returns 5 (usage cap) → exit 5 propagates out
# ───────────────────────────────────────────────────────────────────
@test "conflict resolver exit 5: usage cap propagates out (does not fall back to supervised)" {
  _setup_conflicting_branch

  # Stub: resolver hits usage cap
  attempt_claude_merge_resolution() {
    return 5
  }

  # Capture output and exit code
  # Note: use || exit_code=$? pattern to capture non-zero exit codes; plain || true + $? always gives 0.
  local output exit_code=0
  output=$(_stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "75" "101" 2>&1) || exit_code=$?

  # Must propagate exit 5 exactly (batch-blocking)
  [ "$exit_code" -eq 5 ]

  # Output should mention usage cap
  echo "$output" | grep -qi "usage cap\|usage-cap"

  # Should NOT mention "supervised" as a recovery path (usage cap is batch-blocking)
  # (i.e. it must NOT fall through to the supervised-mode bail message)
  ! echo "$output" | grep -qi "Run.*supervised"

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 4: Exit-5 propagates through check_stale_branch public entry point
# ───────────────────────────────────────────────────────────────────
@test "check_stale_branch: exit 5 propagates from resolver through public entry point" {
  _setup_conflicting_branch

  # Stub: resolver hits usage cap
  attempt_claude_merge_resolution() {
    return 5
  }

  # Set threshold high enough that branch (1 commit behind) takes the rebase path
  export RITE_STALE_BRANCH_THRESHOLD=10

  # Capture output and exit code from the PUBLIC entry point
  # Note: use || exit_code=$? pattern to capture non-zero exit codes; plain || true + $? always gives 0.
  local output exit_code=0
  output=$(check_stale_branch "$WORKTREE_PATH" "101" "75" "unsupervised" 2>&1) || exit_code=$?

  # Must propagate exit 5 exactly through the public entry point
  [ "$exit_code" -eq 5 ]

  # Output should mention usage cap
  echo "$output" | grep -qi "usage cap\|usage-cap"

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}
