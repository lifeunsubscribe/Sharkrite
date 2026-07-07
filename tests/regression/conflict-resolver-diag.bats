#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh, lib/utils/stale-branch.sh, lib/utils/divergence-handler.sh, lib/utils/mid-run-rebase.sh
# tests/regression/conflict-resolver-diag.bats
#
# Verifies that all four conflict-resolver call sites (stale_rebase, stale_merge,
# divergence, mid_run_rebase) emit [diag] CONFLICT_RESOLVER lines with the correct
# outcome= value for every resolver exit code:
#
#   resolved   — attempt_claude_merge_resolution returns 0
#   failed     — attempt_claude_merge_resolution returns 1
#   cap_hit    — attempt_claude_merge_resolution returns 5
#   skipped_no_resolver — resolver function not defined (canary)
#
# These tests are the canary for wiring drift: if a call site stops emitting
# outcome=skipped_no_resolver when the resolver is absent, the canary is broken.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

# ---------------------------------------------------------------------------
# Test setup helpers
# ---------------------------------------------------------------------------

setup() {
  # Pin the LEGACY resolver/abort path: #855's small-branch fast-path (auto-mode
  # conflicts on <=RITE_REBASE_CONFLICT_RESTART_MAX work commits restart fresh)
  # would preempt the resolver contracts these tests pin. 0 disables the
  # fast-path (same pin as the other resolver files — #943 missed this file).
  export RITE_REBASE_CONFLICT_RESTART_MAX=0
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"

  mkdir -p "$RITE_WORKTREE_DIR"
  cd "$FIXTURE_REPO"

  # Set up log file so _diag writes there instead of being a no-op
  DIAG_LOG="$RITE_TEST_TMPDIR/conflict-resolver-diag.log"
  export RITE_LOG_FILE="$DIAG_LOG"
  touch "$DIAG_LOG"

  # Ensure RITE_VERBOSE is off so _diag writes to RITE_LOG_FILE (not stderr)
  unset RITE_VERBOSE
}

teardown() {
  teardown_test_tmpdir
}

# Set up a conflicting branch + worktree.
# After this call, BRANCH_NAME and WORKTREE_PATH are set.
# The feature branch and origin/main both modified README.md (creates rebase conflict).
_setup_conflicting_branch() {
  BRANCH_NAME="fix/diag-conflict-test-$$"

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "Feature change" >> README.md
  git add README.md
  git commit -m "Feature modifies README" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  git checkout main >/dev/null 2>&1
  echo "Main conflicting change" >> README.md
  git add README.md
  git commit -m "Main modifies README (conflict)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-diag-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
}

# Cleanup worktree and remote branch after a test.
_cleanup_branch() {
  cd "$FIXTURE_REPO" 2>/dev/null || true
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# Assert that DIAG_LOG contains a line matching the expected pattern.
# Usage: _assert_diag "context=stale_rebase outcome=resolved"
_assert_diag() {
  local pattern="$1"
  if ! grep -q "$pattern" "$DIAG_LOG"; then
    echo "FAIL: Expected diag pattern '$pattern' not found in $DIAG_LOG" >&2
    echo "Log contents:" >&2
    cat "$DIAG_LOG" >&2
    return 1
  fi
}

# Assert that DIAG_LOG does NOT contain a line matching the pattern.
_refute_diag() {
  local pattern="$1"
  if grep -q "$pattern" "$DIAG_LOG"; then
    echo "FAIL: Unexpected diag pattern '$pattern' found in $DIAG_LOG" >&2
    cat "$DIAG_LOG" >&2
    return 1
  fi
}

# ===========================================================================
# CONTEXT: stale_rebase (stale-branch.sh _stale_rebase_onto_main)
# ===========================================================================

@test "stale_rebase: outcome=resolved emitted when resolver returns 0" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() {
    # Simulate resolution: write clean file, commit, return 0
    cd "$WORKTREE_PATH" || return 1
    echo "Merged" > README.md
    git add README.md
    git commit -m "chore: resolve conflict (stub)" >/dev/null 2>&1
    return 0
  }

  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_rebase outcome=resolved"
  _assert_diag "issue=99"
  _assert_diag "pr=101"
  _assert_diag "duration_s="
  _refute_diag "outcome=skipped_no_resolver"

  _cleanup_branch
}

@test "stale_rebase: outcome=failed emitted when resolver returns 1" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() { return 1; }

  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_rebase outcome=failed"
  _assert_diag "issue=99"
  _assert_diag "pr=101"
  _refute_diag "outcome=skipped_no_resolver"
  [ "$exit_code" -ne 0 ]

  _cleanup_branch
}

@test "stale_rebase: outcome=cap_hit emitted when resolver returns 5" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() { return 5; }

  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_rebase outcome=cap_hit"
  _refute_diag "outcome=skipped_no_resolver"
  [ "$exit_code" -eq 5 ]

  _cleanup_branch
}

@test "stale_rebase: outcome=skipped_no_resolver emitted when resolver is absent (canary)" {
  # Load stale-branch WITHOUT the resolver being defined
  # Undefine attempt_claude_merge_resolution if it was previously loaded
  unset -f attempt_claude_merge_resolution 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  # Explicitly undefine in case conflict-resolver.sh was sourced by stale-branch.sh above
  unset -f attempt_claude_merge_resolution 2>/dev/null || true

  _setup_conflicting_branch

  local exit_code=0
  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  # The canary MUST fire when the resolver function is absent
  _assert_diag "CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver"
  [ "$exit_code" -ne 0 ]

  _cleanup_branch
}

# ===========================================================================
# CONTEXT: stale_merge (stale-branch.sh _stale_merge_main_legacy)
# ===========================================================================

@test "stale_merge: outcome=resolved emitted when resolver returns 0" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Merged" > README.md
    git add README.md
    git commit -m "chore: resolve conflict (stub)" >/dev/null 2>&1
    return 0
  }

  local exit_code=0
  _stale_merge_main_legacy "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_merge outcome=resolved"
  _assert_diag "duration_s="
  _refute_diag "outcome=skipped_no_resolver"

  _cleanup_branch
}

@test "stale_merge: outcome=failed emitted when resolver returns 1" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() { return 1; }

  local exit_code=0
  _stale_merge_main_legacy "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_merge outcome=failed"
  _refute_diag "outcome=skipped_no_resolver"

  _cleanup_branch
}

@test "stale_merge: outcome=cap_hit emitted when resolver returns 5" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() { return 5; }

  local exit_code=0
  _stale_merge_main_legacy "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_merge outcome=cap_hit"
  [ "$exit_code" -eq 5 ]

  _cleanup_branch
}

@test "stale_merge: outcome=skipped_no_resolver emitted when resolver is absent (canary)" {
  unset -f attempt_claude_merge_resolution 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  unset -f attempt_claude_merge_resolution 2>/dev/null || true

  _setup_conflicting_branch

  local exit_code=0
  _stale_merge_main_legacy "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=stale_merge outcome=skipped_no_resolver"

  _cleanup_branch
}

@test "stale_merge: caller commits staged resolution — resolver-stages/caller-commits contract" {
  # Regression for the CRITICAL bug where _stale_merge_main_legacy ran verify_post_merge
  # and git push against staged-but-uncommitted work, silently discarding the resolution.
  #
  # This stub only stages the resolved file (no git commit) — exactly what the real
  # conflict-resolver.sh does per contract line 10. The test asserts that the caller
  # (_stale_merge_main_legacy) issues the commit and that the resolution is present in HEAD.
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  _setup_conflicting_branch

  # Override verify_post_merge to always pass (we're testing the commit contract, not tests)
  verify_post_merge() { return 0; }

  attempt_claude_merge_resolution() {
    # Stages-only stub: mirrors exactly what conflict-resolver.sh does per contract line 10.
    # The real resolver aborts the first failed merge, then re-runs git merge to get conflict
    # markers (step 3, conflict-resolver.sh:160), which sets MERGE_HEAD. It then stages the
    # resolved files and returns 0 WITHOUT committing — the caller is responsible for the commit.
    #
    # We replicate that here: abort the in-progress merge, restart it (sets MERGE_HEAD), write
    # the resolved content, stage it, then return 0 without committing.
    cd "$WORKTREE_PATH" || return 1
    git merge --abort 2>/dev/null || true
    # Restart merge so MERGE_HEAD is set (conflict-resolver.sh step 3 pattern)
    git merge origin/main --no-edit 2>/dev/null || true  # expected to leave conflict markers
    echo "Resolved content" > README.md
    git add README.md
    return 0
  }

  local exit_code=0
  _stale_merge_main_legacy "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "99" "101" || exit_code=$?

  # The function must succeed
  [ "$exit_code" -eq 0 ]

  # The resolution must be committed to HEAD — not just staged
  cd "$WORKTREE_PATH" || return 1
  local head_content
  head_content=$(git show HEAD:README.md 2>/dev/null || true)
  if [ "$head_content" != "Resolved content" ]; then
    echo "FAIL: Resolution not committed to HEAD — staged-only content was not committed by caller" >&2
    echo "HEAD README.md content: '$head_content'" >&2
    git log --oneline -3 >&2
    git status >&2
    return 1
  fi
  cd "$FIXTURE_REPO" || true

  _cleanup_branch
}

# ===========================================================================
# CONTEXT: divergence (divergence-handler.sh _do_rebase_and_push)
# ===========================================================================

# Helper: set up a branch where local and remote have diverged with conflicts.
# _do_rebase_and_push does `git rebase origin/BRANCH_NAME` so we need
# the remote branch to have conflicting commits vs. the local worktree.
#
# Scenario:
#   1. Create branch, push (local == remote)
#   2. Create worktree for the branch
#   3. Advance origin/BRANCH_NAME via a second clone (avoids worktree checkout
#      restriction — a branch can only be checked out in one worktree at a time)
#   4. Add a LOCAL conflicting commit to the worktree
# Result: `git rebase origin/BRANCH_NAME` in the worktree will fail with conflict.
_setup_diverged_branch() {
  BRANCH_NAME="fix/diag-diverge-test-$$"

  # Create branch and push (both sides start equal)
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "Initial branch content" >> README.md
  git add README.md
  git commit -m "Initial branch commit" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Return to main before adding the worktree — a branch can only be checked out
  # in one worktree at a time, and we're still on $BRANCH_NAME here.
  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-div-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  # Advance origin/BRANCH_NAME via a second clone.
  # We cannot `git checkout $BRANCH_NAME` in the fixture repo because the branch
  # is already checked out in the worktree above (git enforces single-checkout).
  # A second clone of the bare remote has no such restriction.
  local _second_clone="${RITE_TEST_TMPDIR}/second-clone-$$"
  git clone "$BARE_REMOTE" "$_second_clone" >/dev/null 2>&1
  git -C "$_second_clone" config user.name "Test User"
  git -C "$_second_clone" config user.email "test@example.com"
  git -C "$_second_clone" checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME" >/dev/null 2>&1
  echo "Remote conflicting change to README" >> "$_second_clone/README.md"
  git -C "$_second_clone" add README.md
  git -C "$_second_clone" commit -m "Remote conflicting commit" >/dev/null 2>&1
  git -C "$_second_clone" push --force-with-lease origin "$BRANCH_NAME" >/dev/null 2>&1

  # Fetch the updated remote ref so the worktree sees origin/BRANCH_NAME
  git -C "$WORKTREE_PATH" fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # Add a LOCAL conflicting change in the worktree (different content, same file).
  cd "$WORKTREE_PATH" || return 1
  echo "Local conflicting change to README" >> README.md
  git add README.md
  git commit -m "Local conflicting commit" >/dev/null 2>&1
  cd "$FIXTURE_REPO" || return 1
}

@test "divergence: outcome=resolved emitted when resolver returns 0" {
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
  _setup_diverged_branch

  attempt_claude_merge_resolution() {
    # Resolve: write clean file, stage, commit
    echo "Merged content" > README.md
    git add README.md
    git commit -m "chore: resolve conflict (stub)" >/dev/null 2>&1
    return 0
  }

  # _do_rebase_and_push requires CWD inside the worktree
  cd "$WORKTREE_PATH" || return 1
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "99" "101" || exit_code=$?
  cd "$FIXTURE_REPO" || true

  _assert_diag "CONFLICT_RESOLVER context=divergence outcome=resolved"
  _assert_diag "duration_s="
  _refute_diag "outcome=skipped_no_resolver"

  _cleanup_branch
}

@test "divergence: outcome=failed emitted when resolver returns 1" {
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
  _setup_diverged_branch

  attempt_claude_merge_resolution() { return 1; }

  cd "$WORKTREE_PATH" || return 1
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "99" "101" || exit_code=$?
  cd "$FIXTURE_REPO" || true

  _assert_diag "CONFLICT_RESOLVER context=divergence outcome=failed"
  [ "$exit_code" -ne 0 ]

  _cleanup_branch
}

@test "divergence: outcome=cap_hit emitted when resolver returns 5" {
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
  _setup_diverged_branch

  attempt_claude_merge_resolution() { return 5; }

  cd "$WORKTREE_PATH" || return 1
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "99" "101" || exit_code=$?
  cd "$FIXTURE_REPO" || true

  _assert_diag "CONFLICT_RESOLVER context=divergence outcome=cap_hit"
  [ "$exit_code" -eq 5 ]

  _cleanup_branch
}

@test "divergence: outcome=skipped_no_resolver emitted when resolver is absent (canary)" {
  unset -f attempt_claude_merge_resolution 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
  unset -f attempt_claude_merge_resolution 2>/dev/null || true

  _setup_diverged_branch

  cd "$WORKTREE_PATH" || return 1
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "99" "101" || exit_code=$?
  cd "$FIXTURE_REPO" || true

  _assert_diag "CONFLICT_RESOLVER context=divergence outcome=skipped_no_resolver"

  _cleanup_branch
}

# ===========================================================================
# CONTEXT: mid_run_rebase (mid-run-rebase.sh _mid_run_rebase_onto_main)
# ===========================================================================

@test "mid_run_rebase: outcome=resolved emitted when resolver returns 0" {
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Merged" > README.md
    git add README.md
    git commit -m "chore: resolve conflict (stub)" >/dev/null 2>&1
    return 0
  }

  local exit_code=0
  _mid_run_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "99" "101" "auto" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=resolved"
  _assert_diag "duration_s="
  _refute_diag "outcome=skipped_no_resolver"

  _cleanup_branch
}

@test "mid_run_rebase: outcome=failed emitted when resolver returns 1" {
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() { return 1; }

  local exit_code=0
  _mid_run_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "99" "101" "auto" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=failed"
  _refute_diag "outcome=skipped_no_resolver"
  [ "$exit_code" -ne 0 ]

  _cleanup_branch
}

@test "mid_run_rebase: outcome=cap_hit emitted when resolver returns 5" {
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
  _setup_conflicting_branch

  attempt_claude_merge_resolution() { return 5; }

  local exit_code=0
  _mid_run_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "99" "101" "auto" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=cap_hit"
  [ "$exit_code" -eq 5 ]

  _cleanup_branch
}

@test "mid_run_rebase: outcome=skipped_no_resolver emitted when resolver is absent (canary)" {
  unset -f attempt_claude_merge_resolution 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
  unset -f attempt_claude_merge_resolution 2>/dev/null || true

  _setup_conflicting_branch

  local exit_code=0
  _mid_run_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "99" "101" "auto" || exit_code=$?

  _assert_diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=skipped_no_resolver"
  [ "$exit_code" -ne 0 ]

  _cleanup_branch
}
