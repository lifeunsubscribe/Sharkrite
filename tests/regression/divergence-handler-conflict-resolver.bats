#!/usr/bin/env bats
# tests/regression/divergence-handler-conflict-resolver.bats
#
# Tests that divergence-handler conflict bail paths invoke attempt_claude_merge_resolution
# and handle all three documented exit codes correctly:
#
#   0 = resolved — continue workflow (verify + push and return 0)
#   1 = failure  — block in auto mode, return 1
#   5 = usage cap — propagate exit 5 out (do NOT fall back to supervised)
#
# The tests stub attempt_claude_merge_resolution as a shell function so they
# work independently of conflict-resolver.sh landing (issue #21).
#
# Also verifies that the resolver is NOT invoked in supervised mode
# (supervised mode uses interactive prompts, not the resolver).
#
# Verifies fix for issue #104: Resolver invoked after conflict state aborted.

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

  # Source the divergence-handler library (conflict-resolver.sh may not exist — that's fine)
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────
# Shared helper: create a conflicting divergence scenario.
#
# Sets WORKTREE_PATH and BRANCH_NAME in the caller's scope.
# After this call, the local branch and origin/BRANCH_NAME have diverged
# such that rebasing local onto origin produces a conflict in README.md.
# ───────────────────────────────────────────────────────────────────
_setup_diverging_branch() {
  BRANCH_NAME="fix/diverge-test-$$"

  # Feature branch modifies README.md — overwrite line 1 with branch-specific content
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "# Feature: branch-specific content" > README.md
  git add README.md
  git commit -m "Feature changes README" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Remote branch also modifies README.md line 1 differently — produces a real rebase conflict
  # because both sides replace the same line (not a simple append-to-EOF that git auto-merges).
  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Test User"
  git -C "$tmp_clone" config user.email "test@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "# Feature: remote-specific content" > "$tmp_clone/README.md"
  git -C "$tmp_clone" add README.md
  git -C "$tmp_clone" commit -m "Remote conflicting change" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1

  # Create a worktree on the local (non-updated) branch — diverged from remote
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-diverge-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  cd "$WORKTREE_PATH"

  # Verify the conflict setup is correct: rebase onto origin must actually conflict.
  # Fetch remote state so git knows about origin/$BRANCH_NAME divergence.
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1
  # Sentinel assertion: a plain rebase must fail (the fixture produces a real conflict).
  if git rebase "origin/$BRANCH_NAME" >/dev/null 2>&1; then
    git rebase --abort 2>/dev/null || true
    echo "ERROR: _setup_diverging_branch: rebase succeeded — fixture does not produce a conflict. Check that both sides modify the same line." >&2
    return 1
  fi
  git rebase --abort >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 1: Resolver returns 0 (resolved) → workflow continues and pushes
# ───────────────────────────────────────────────────────────────────
@test "divergence: conflict resolver exit 0 — resolved by Claude, push succeeds" {
  _setup_diverging_branch

  # Stub: resolver "resolves" by creating a valid commit on the branch
  attempt_claude_merge_resolution() {
    local branch="$1"
    cd "$WORKTREE_PATH" || return 1
    echo "# Feature: merged content" > README.md
    git add README.md
    git commit -m "chore: resolve rebase conflict (stub)" >/dev/null 2>&1
    return 0
  }

  # Run _do_rebase_and_push in auto mode — should call resolver and succeed
  _do_rebase_and_push "$BRANCH_NAME" "true" "104" "103"
  local exit_code=$?

  # Should succeed (exit 0 = continue workflow)
  [ "$exit_code" -eq 0 ]

  # Verify the branch was pushed (remote matches local HEAD)
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
# Test 2: Resolver returns 1 (cannot resolve) → auto mode blocks
# ───────────────────────────────────────────────────────────────────
@test "divergence: conflict resolver exit 1 — resolver fails, auto mode blocks with non-zero" {
  _setup_diverging_branch

  # Stub: resolver fails (conflicts too complex)
  attempt_claude_merge_resolution() {
    return 1
  }

  # Capture stderr for message assertions
  local output
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "104" "103" 2>&1) || true
  local exit_code=$?

  # Should return non-zero (auto mode bail)
  [ "$exit_code" -ne 0 ]

  # Should NOT have propagated exit 5
  [ "$exit_code" -ne 5 ]

  # Verify rebase was cleanly aborted (no leftover rebase state)
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
@test "divergence: conflict resolver exit 5 — usage cap propagates (does not fall back to supervised)" {
  _setup_diverging_branch

  # Stub: resolver hits usage cap
  attempt_claude_merge_resolution() {
    return 5
  }

  # Capture output and exit code
  local output
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "104" "103" 2>&1) || true
  local exit_code=$?

  # Must propagate exit 5 exactly (batch-blocking)
  [ "$exit_code" -eq 5 ]

  # Output should mention usage cap
  echo "$output" | grep -qi "usage cap\|usage-cap"

  # Should NOT mention "supervised" as a recovery path
  ! echo "$output" | grep -qi "Run.*supervised"

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 4: Resolver NOT invoked when conflict-resolver.sh is absent
# (function undefined) — auto mode bails without attempting resolution
# ───────────────────────────────────────────────────────────────────
@test "divergence: no resolver function defined — auto mode bails without calling it" {
  _setup_diverging_branch

  # Ensure the resolver function is NOT defined
  unset -f attempt_claude_merge_resolution 2>/dev/null || true

  local output
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "104" "103" 2>&1) || true
  local exit_code=$?

  # Should fail (conflicts, no resolver)
  [ "$exit_code" -ne 0 ]

  # Should NOT exit 5 (no usage cap path hit)
  [ "$exit_code" -ne 5 ]

  # Output should NOT mention "Attempting Claude-assisted conflict resolution"
  ! echo "$output" | grep -qi "Attempting Claude"

  # Rebase state should be clean (aborted)
  [ ! -d "$WORKTREE_PATH/.git/rebase-merge" ]
  [ ! -d "$WORKTREE_PATH/.git/rebase-apply" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 5: Exit-5 propagates through handle_push_divergence public entry point
# ───────────────────────────────────────────────────────────────────
@test "divergence: exit 5 propagates from resolver through handle_push_divergence entry point" {
  _setup_diverging_branch

  # Stub: resolver hits usage cap
  attempt_claude_merge_resolution() {
    return 5
  }

  # Must be in worktree for divergence detection to work
  cd "$WORKTREE_PATH"

  # Fetch so detect_divergence can compare local vs remote
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # Capture output and exit code from the PUBLIC entry point
  local output
  output=$(handle_push_divergence "$BRANCH_NAME" "104" "103" "true" 2>&1) || true
  local exit_code=$?

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
