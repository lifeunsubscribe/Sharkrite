#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh
# tests/regression/stale-branch-conflict-restart.bats
#
# Tests that auto mode + rebase conflict + small branch (≤ RITE_REBASE_CONFLICT_RESTART_MAX)
# triggers close-and-restart (exit 11) instead of LLM resolution.
#
# Verifies fix for issue #855: Restart small branches on auto rebase conflicts.
#
# Acceptance criteria pinned:
#   - 2-commit conflicting branch → exit 11 (restart), no LLM resolution attempted
#   - 5-commit conflicting branch → LLM resolution attempted (default threshold is 3)
#   - Supervised mode → prompts (unchanged)

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

  # Source the stale-branch library
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Stub gh_safe so close-and-cleanup doesn't hit GitHub
  # Re-stub AFTER sourcing (env-guarded libs overwrite pre-source stubs — runbook rule 2)
  gh_safe() { return 0; }
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────
# Shared helper: create a conflicting branch with N work commits.
#
# Sets WORKTREE_PATH and BRANCH_NAME in the caller's scope.
# The branch conflicts with origin/main via README.md.
# ───────────────────────────────────────────────────────────────────
_setup_conflicting_branch_with_commits() {
  local num_commits="${1:-2}"
  BRANCH_NAME="fix/conflict-restart-test-$$"

  # Feature branch: add N commits (the last one modifies README.md to cause conflict)
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  local i
  for i in $(seq 1 "$num_commits"); do
    if [ "$i" -lt "$num_commits" ]; then
      # Non-conflicting earlier commits
      echo "feature work $i" > "feature-${i}.txt"
      git add "feature-${i}.txt"
    else
      # Final commit: modify README.md to produce rebase conflict with main
      echo "Feature line" >> README.md
      git add README.md
    fi
    git commit -m "Feature commit $i" >/dev/null 2>&1
  done
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Main also modifies README.md — produces rebase conflict
  git checkout main >/dev/null 2>&1
  echo "Main line (conflict)" >> README.md
  git add README.md
  git commit -m "Main changes README" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree from the feature branch
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-restart-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────
# Test 1: 2-commit branch (≤ default threshold 3) → exit 11, no LLM
# ───────────────────────────────────────────────────────────────────
@test "small branch (2 commits): conflict in auto mode exits 11 and skips LLM resolution" {
  _setup_conflicting_branch_with_commits 2

  # Track whether LLM resolution was attempted
  local llm_called=false
  attempt_claude_merge_resolution() {
    llm_called=true
    return 0
  }

  unset RITE_REBASE_CONFLICT_RESTART_MAX  # use default (3)

  # Run the rebase — should close-and-restart (exit 11)
  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "821" "999" 2>/dev/null || exit_code=$?

  # Must exit 11 (restart fresh)
  [ "$exit_code" -eq 11 ]

  # LLM resolution must NOT have been called
  [ "$llm_called" = false ]

  # Worktree should be gone (cleaned up by close-and-restart)
  [ ! -d "$WORKTREE_PATH" ]
}

# ───────────────────────────────────────────────────────────────────
# Test 2: 5-commit branch (> default threshold 3) → LLM resolution attempted
# ───────────────────────────────────────────────────────────────────
@test "large branch (5 commits): conflict in auto mode attempts LLM resolution (not restart)" {
  _setup_conflicting_branch_with_commits 5

  # Track whether LLM resolution was attempted
  local llm_called=false
  attempt_claude_merge_resolution() {
    llm_called=true
    return 1  # fail: we're testing that it's called, not that it succeeds
  }

  unset RITE_REBASE_CONFLICT_RESTART_MAX  # use default (3)

  # Run the rebase — 5 commits > threshold 3, should attempt LLM (then fail/bail)
  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "821" "999" 2>/dev/null || exit_code=$?

  # Must NOT exit 11 (not a restart)
  [ "$exit_code" -ne 11 ]

  # LLM resolution MUST have been called
  [ "$llm_called" = true ]

  # Clean up (worktree was not removed by the bail path)
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 3: Config knob — RITE_REBASE_CONFLICT_RESTART_MAX=5 promotes
#         a 5-commit branch into the restart path
# ───────────────────────────────────────────────────────────────────
@test "config knob: RITE_REBASE_CONFLICT_RESTART_MAX=5 restarts a 5-commit branch" {
  _setup_conflicting_branch_with_commits 5

  local llm_called=false
  attempt_claude_merge_resolution() {
    llm_called=true
    return 0
  }

  export RITE_REBASE_CONFLICT_RESTART_MAX=5

  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "821" "999" 2>/dev/null || exit_code=$?

  # With threshold=5, a 5-commit branch (≤5) should restart (exit 11)
  [ "$exit_code" -eq 11 ]

  # LLM resolution must NOT have been called
  [ "$llm_called" = false ]

  # Worktree should be gone
  [ ! -d "$WORKTREE_PATH" ]
}

# ───────────────────────────────────────────────────────────────────
# Test 4: Config knob — RITE_REBASE_CONFLICT_RESTART_MAX=0 disables
#         the fast-path entirely even for a 1-commit branch
# ───────────────────────────────────────────────────────────────────
@test "config knob: RITE_REBASE_CONFLICT_RESTART_MAX=0 disables fast-path (always LLM)" {
  _setup_conflicting_branch_with_commits 1

  local llm_called=false
  attempt_claude_merge_resolution() {
    llm_called=true
    return 1
  }

  export RITE_REBASE_CONFLICT_RESTART_MAX=0

  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "821" "999" 2>/dev/null || exit_code=$?

  # With threshold=0, even a 1-commit branch (1 > 0) should NOT restart
  [ "$exit_code" -ne 11 ]

  # LLM resolution MUST have been called
  [ "$llm_called" = true ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 5: Supervised mode — conflict with small branch still prompts
#         (the restart fast-path is auto-only)
# ───────────────────────────────────────────────────────────────────
@test "supervised mode: small branch conflict still prompts (not auto-restarted)" {
  _setup_conflicting_branch_with_commits 2

  local llm_called=false
  attempt_claude_merge_resolution() {
    llm_called=true
    return 0
  }

  unset RITE_REBASE_CONFLICT_RESTART_MAX  # use default (3)

  # Feed "d" (abort) to stdin so the supervised prompt doesn't hang.
  # Use a here-string (<<<) rather than a pipe so the function runs in the
  # current shell — a pipe would run it in a subshell and mutations to
  # llm_called would be invisible to the assertion below.
  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "supervised" "821" "999" 2>/dev/null <<< "d" || exit_code=$?

  # Supervised mode with "d" (abort) → exit 1, not exit 11
  [ "$exit_code" -ne 11 ]

  # LLM resolution must NOT be called in supervised mode (prompt is used instead)
  [ "$llm_called" = false ]

  # Clean up (worktree was NOT removed — supervised aborted, no cleanup)
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 6: Exit 11 propagates through check_stale_branch public entry point
# ───────────────────────────────────────────────────────────────────
@test "check_stale_branch: exit 11 propagates when small branch hits conflict in auto mode" {
  _setup_conflicting_branch_with_commits 2

  local llm_called=false
  attempt_claude_merge_resolution() {
    llm_called=true
    return 0
  }

  # Set threshold high enough that the branch (below threshold) takes the rebase path
  export RITE_STALE_BRANCH_THRESHOLD=10
  unset RITE_REBASE_CONFLICT_RESTART_MAX  # use default (3)

  local exit_code=0
  check_stale_branch "$WORKTREE_PATH" "999" "821" "auto" 2>/dev/null || exit_code=$?

  # Must propagate exit 11 through the public entry point
  [ "$exit_code" -eq 11 ]

  # LLM resolution must NOT have been called
  [ "$llm_called" = false ]
}
