#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/mid-run-rebase.sh, lib/utils/stale-branch.sh, lib/core/workflow-runner.sh
# tests/regression/parallel-paths-target-base.bats
#
# Regression tests for target-branch awareness in the parallel rebase/resolver paths.
#
# Design reference: docs/architecture/branch-flag-design.md §5.2
# Issue: #1035/1036/1037 (make parallel rebase/resolver paths target-aware)
#
# Coverage:
#   1. _stale_resolve_base_branch — cold-start RITE_TARGET_BRANCH tier:
#        a. no PR + RITE_TARGET_BRANCH=feature-x → feature-x
#        b. stubbed PR baseRefName=release/1 + RITE_TARGET_BRANCH=feature-x → release/1 (API wins)
#        c. invalid-charset env value (bad;name) → main (falls back)
#        d. '..' path-traversal env value (a..b) → main (falls back)
#        e. env unset + no PR → main (default)
#   2. Discriminating semantic test — check_and_rebase_against_main with base=feature-x
#      detects conflict against origin/feature-x (returns 1) where a main-pinned check
#      would have returned 0 (no conflict with main).
#   3. --merge-target arg invariant — _stale_rebase_onto_main with base=feature-x
#      invokes the resolver with --merge-target origin/feature-x.
#   4. Default parity — no 6th arg / env unset: mid-run check behaves as before
#      (conflict against main returns 1; clean branch returns 0; messages reference main).
#   5. Integration branch skip guard — branch == base_branch → returns 0.

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
  export RITE_LOG_FILE="/dev/null"

  mkdir -p "$RITE_WORKTREE_DIR"

  # Set threshold so rebase path is taken (branch 1 commit behind < 10 default)
  export RITE_REBASE_CONFLICT_RESTART_MAX=0

  cd "$FIXTURE_REPO"

  # Source stale-branch (provides _stale_resolve_base_branch + _stale_rebase_onto_main)
  # Stub deps before sourcing to avoid side effects
  create_sharkrite_stash() { return 0; }
  verify_post_merge()      { return 0; }
  export -f create_sharkrite_stash verify_post_merge

  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ===========================================================================
# § 1. _stale_resolve_base_branch — cold-start RITE_TARGET_BRANCH tier
# ===========================================================================

@test "_stale_resolve_base_branch: no PR + RITE_TARGET_BRANCH=feature-x -> feature-x" {
  # Tier 1 (API) is skipped — no PR number. Env transport should win.
  gh_safe() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f gh_safe

  export RITE_TARGET_BRANCH="feature-x"
  _stale_resolve_base_branch ""
  [ "$_STALE_BASE_BRANCH" = "feature-x" ] || {
    echo "FAIL: expected 'feature-x', got '$_STALE_BASE_BRANCH'"
    return 1
  }
  [ "$_STALE_BASE_BRANCH_SOURCE" = "fallback" ]
}

@test "_stale_resolve_base_branch: stubbed PR baseRefName=release/1 + RITE_TARGET_BRANCH=feature-x -> release/1 (API wins)" {
  # Tier 1 (API) wins over env transport.
  gh_safe() { echo "release/1"; }
  export -f gh_safe

  export RITE_TARGET_BRANCH="feature-x"
  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "release/1" ] || {
    echo "FAIL: expected 'release/1' (API should win), got '$_STALE_BASE_BRANCH'"
    return 1
  }
  [ "$_STALE_BASE_BRANCH_SOURCE" = "api" ]
}

@test "_stale_resolve_base_branch: invalid-charset env value (bad;name) -> main" {
  gh_safe() { echo ""; }
  export -f gh_safe

  export RITE_TARGET_BRANCH="bad;name"
  _stale_resolve_base_branch ""
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main' (invalid charset rejected), got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: path-traversal env value (a..b) -> main" {
  gh_safe() { echo ""; }
  export -f gh_safe

  export RITE_TARGET_BRANCH="a..b"
  _stale_resolve_base_branch ""
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main' (path traversal rejected), got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: env unset + no PR -> main" {
  gh_safe() { echo ""; }
  export -f gh_safe

  unset RITE_TARGET_BRANCH
  _stale_resolve_base_branch ""
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main' (env unset + no PR), got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

# ===========================================================================
# § 2. Discriminating semantic test — target-aware vs main-pinned check
# ===========================================================================
#
# Fixture: a branch that conflicts with origin/feature-x but NOT with origin/main.
# - check_and_rebase_against_main ... feature-x  → returns 1 (conflict detected)
# - check_and_rebase_against_main ... (no 6th arg, defaults to main) → returns 0 (clean)
#
# This proves the parameterization is operative, not cosmetic.

_setup_conflict_with_feature_x_not_main() {
  BRANCH_NAME="fix/target-aware-test-$$"

  # Create 'feature-x' integration branch from main and push it as the "target"
  git checkout -b feature-x main >/dev/null 2>&1
  echo "# feature-x specific content" > feature-x.txt
  git add feature-x.txt
  git commit -m "feature-x: add specific file" >/dev/null 2>&1
  git push -u origin feature-x >/dev/null 2>&1

  # Create our feature branch from main (NOT from feature-x)
  git checkout main >/dev/null 2>&1
  git checkout -b "$BRANCH_NAME" >/dev/null 2>&1
  # Modify the same file that feature-x will also modify (to produce a conflict)
  echo "branch version of conflict-file" > conflict-file.txt
  git add conflict-file.txt
  git commit -m "branch: add conflict-file.txt" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1
  BRANCH_HEAD=$(git rev-parse HEAD)

  # Advance origin/feature-x with a conflicting change to the SAME file
  git checkout feature-x >/dev/null 2>&1
  echo "feature-x version of conflict-file (DIFFERENT content = conflict)" > conflict-file.txt
  git add conflict-file.txt
  git commit -m "feature-x: advance with conflict on same file" >/dev/null 2>&1
  git push origin feature-x >/dev/null 2>&1

  # main stays clean — no changes to conflict-file.txt on main
  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-target-aware-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  # Source mid-run-rebase.sh for the check_and_rebase_against_main function
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  # Stub the conflict resolver to fail so we exercise the abort contract
  attempt_claude_merge_resolution() { return 1; }
}

@test "check_and_rebase_against_main: target=feature-x detects conflict (returns 1)" {
  _setup_conflict_with_feature_x_not_main

  # With base=feature-x: branch has content conflict with origin/feature-x
  run check_and_rebase_against_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "999" "888" "unsupervised" "feature-x"

  [ "$status" -eq 1 ] || {
    echo "FAIL: expected exit 1 (conflict with feature-x), got $status"
    return 1
  }

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" feature-x >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" feature-x >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: default (no 6th arg) — clean against main, returns 0" {
  _setup_conflict_with_feature_x_not_main

  # Without 6th arg (defaults to main): branch has NO conflict with main — should return 0.
  # (main was never modified, so the branch merges cleanly into it.)
  run check_and_rebase_against_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "999" "888" "unsupervised"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (clean against main), got $status (discriminating test: main-pinned would be clean)"
    return 1
  }

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" feature-x >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" feature-x >/dev/null 2>&1 || true
}

# ===========================================================================
# § 3. --merge-target arg invariant — _stale_rebase_onto_main
# ===========================================================================
#
# Recording stub: assert _stale_rebase_onto_main with base=feature-x passes
# --merge-target "origin/feature-x" to the resolver.
# Pattern mirrors divergence-merge-target-passed-to-resolver.bats Test 1.

_setup_conflicting_branch_against_feature_x() {
  BRANCH_NAME="fix/merge-target-stale-$$"

  # Create feature-x as a target integration branch
  git checkout -b feature-x main >/dev/null 2>&1
  echo "integration content" > integration.txt
  git add integration.txt
  git commit -m "feature-x: init" >/dev/null 2>&1
  git push -u origin feature-x >/dev/null 2>&1

  # Create feature branch from main, modifying the same file
  git checkout main >/dev/null 2>&1
  git checkout -b "$BRANCH_NAME" >/dev/null 2>&1
  echo "feature branch version" > integration.txt
  git add integration.txt
  git commit -m "branch: modify integration.txt" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Advance feature-x with a conflict on the same file
  git checkout feature-x >/dev/null 2>&1
  echo "feature-x conflicting version" > integration.txt
  git add integration.txt
  git commit -m "feature-x: conflicting change" >/dev/null 2>&1
  git push origin feature-x >/dev/null 2>&1

  git checkout main >/dev/null 2>&1
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-merge-target-stale-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
}

@test "_stale_rebase_onto_main: resolver called with --merge-target origin/feature-x (not origin/main)" {
  _setup_conflicting_branch_against_feature_x

  # Recording stub — captures the --merge-target arg
  _captured_merge_target=""
  attempt_claude_merge_resolution() {
    while [ $# -gt 0 ]; do
      case "$1" in
        --merge-target) _captured_merge_target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # Return 1 (failure) — we only need to capture the arg; no need to resolve
    return 1
  }

  # Must pin restart-max=0 so the small-branch fast-path doesn't preempt the resolver
  export RITE_REBASE_CONFLICT_RESTART_MAX=0

  # Fetch feature-x so _stale_rebase_onto_main can verify origin/feature-x exists
  git -C "$WORKTREE_PATH" fetch origin feature-x >/dev/null 2>&1

  local exit_code=0
  _stale_rebase_onto_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "unsupervised" "999" "888" "feature-x" 2>/dev/null || exit_code=$?

  # Resolver was called (exit_code is non-0 since stub returned 1, but stub must have been invoked)
  # The key assertion is the captured merge target
  [ "$_captured_merge_target" = "origin/feature-x" ] || {
    echo "FAIL: expected --merge-target 'origin/feature-x', got '$_captured_merge_target'"
    return 1
  }

  # Explicitly assert NOT origin/main (the pre-fix wrong value)
  [ "$_captured_merge_target" != "origin/main" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" feature-x >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" feature-x >/dev/null 2>&1 || true
}

# ===========================================================================
# § 4. Default parity — mid-run check with no 6th arg behaves as before
# ===========================================================================

_setup_conflict_with_main() {
  BRANCH_NAME2="fix/default-parity-$$"

  # Source mid-run-rebase.sh for check_and_rebase_against_main
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  # Create feature branch with a commit
  git checkout -b "$BRANCH_NAME2" main >/dev/null 2>&1
  echo "feature content" > feature.txt
  git add feature.txt
  git commit -m "feature: add file" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME2" >/dev/null 2>&1
  BRANCH_HEAD2=$(git rev-parse HEAD)

  # Advance main with a conflicting change to the same file
  git checkout main >/dev/null 2>&1
  echo "main conflicting version" > feature.txt
  git add feature.txt
  git commit -m "main: conflict on feature.txt" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  git checkout main >/dev/null 2>&1
  WORKTREE_PATH2="$RITE_WORKTREE_DIR/issue-parity-$$"
  git worktree add "$WORKTREE_PATH2" "$BRANCH_NAME2" >/dev/null 2>&1

  # Stub resolver to fail (test the abort contract)
  attempt_claude_merge_resolution() { return 1; }
}

@test "check_and_rebase_against_main: default (main) — conflict case returns 1 (parity)" {
  _setup_conflict_with_main

  run check_and_rebase_against_main \
    "$WORKTREE_PATH2" "$BRANCH_NAME2" "777" "666" "unsupervised"

  [ "$status" -eq 1 ] || {
    echo "FAIL: expected exit 1 (conflict with main, default parity), got $status"
    return 1
  }

  # Message must mention the base branch (default = main)
  [[ "$output" =~ "main" ]] || {
    echo "FAIL: output should mention 'main' for default base; got: $output"
    return 1
  }

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH2" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME2" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME2" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: default (main) — clean case returns 0 (parity)" {
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  BRANCH_CLEAN="fix/default-clean-$$"

  # Feature branch touches a file that main never touches
  git checkout -b "$BRANCH_CLEAN" main >/dev/null 2>&1
  echo "isolated feature" > isolated-feature.txt
  git add isolated-feature.txt
  git commit -m "feature: isolated file" >/dev/null 2>&1
  git push -u origin "$BRANCH_CLEAN" >/dev/null 2>&1
  local head_before
  head_before=$(git rev-parse HEAD)

  # Advance main with a commit on a different file
  git checkout main >/dev/null 2>&1
  echo "main progress" > main-only.txt
  git add main-only.txt
  git commit -m "main: unrelated change" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  git checkout main >/dev/null 2>&1
  WORKTREE_CLEAN="$RITE_WORKTREE_DIR/issue-clean-$$"
  git worktree add "$WORKTREE_CLEAN" "$BRANCH_CLEAN" >/dev/null 2>&1

  run check_and_rebase_against_main \
    "$WORKTREE_CLEAN" "$BRANCH_CLEAN" "555" "444" "unsupervised"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (clean against main, default parity), got $status"
    return 1
  }

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_CLEAN" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_CLEAN" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_CLEAN" >/dev/null 2>&1 || true
}

# ===========================================================================
# § 5. Integration branch skip guard — check returns 0 when branch == base
# ===========================================================================

@test "check_and_rebase_against_main: branch == base_branch → returns 0 (skip guard)" {
  # When the branch being checked IS the base branch, the function should skip
  # rather than try to rebase the integration branch onto itself.
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  local worktree_path="$RITE_WORKTREE_DIR/issue-skip-guard-$$"
  git worktree add "$worktree_path" main >/dev/null 2>&1

  # Call with branch_name == base_branch — should skip (return 0)
  run check_and_rebase_against_main \
    "$worktree_path" "feature-x" "1" "2" "unsupervised" "feature-x"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (branch == base skip guard), got $status"
    return 1
  }

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
}
