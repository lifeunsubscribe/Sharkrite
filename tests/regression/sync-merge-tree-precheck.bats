#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/integration-sync.sh::sync_issue_branch
# tests/regression/sync-merge-tree-precheck.bats
#
# Regression tests for the merge-tree precheck and resolver wiring in
# sync_issue_branch (rite --sync <N>, #1462).
#
# Two defects fixed:
#   1. Unconditional rebase re-litigated conflicts already resolved in merge
#      commits on the branch. Now: merge-tree precheck exits early (outcome=current)
#      when the branch merges cleanly, regardless of commit distance.
#   2. Rebase conflict bailed to manual immediately. Now: attempt_claude_merge_resolution
#      is invoked (with the same declare -f guard as the --sync <branch> path) before
#      the manual-resolution hint becomes the response.
#
# Test strategy:
#   - Structural greps for the invariant contracts (merge-tree precheck present,
#     resolver guard present, manual fallback preserved).
#   - One behavioral test using a local git fixture: behind-but-clean branch →
#     HEAD unchanged, outcome=current.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Structural: merge-tree precheck is present inside sync_issue_branch.
# ---------------------------------------------------------------------------
@test "sync_issue_branch contains merge-tree precheck (not just in sync_integration_branch)" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | grep -q 'merge-tree'
}

# ---------------------------------------------------------------------------
# Structural: attempt_claude_merge_resolution is called in sync_issue_branch.
# ---------------------------------------------------------------------------
@test "sync_issue_branch calls attempt_claude_merge_resolution on rebase conflict" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | grep -q 'attempt_claude_merge_resolution'
}

# ---------------------------------------------------------------------------
# Structural: resolver call is guarded by declare -f (same as --sync <branch> path).
# ---------------------------------------------------------------------------
@test "sync_issue_branch resolver is guarded by declare -f check" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" \
    | grep -q 'declare -f attempt_claude_merge_resolution'
}

# ---------------------------------------------------------------------------
# Structural: manual-resolution hint is still present as the fallback.
# ---------------------------------------------------------------------------
@test "sync_issue_branch still contains manual-resolution hint as fallback" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | grep -q 'resolve manually'
}

# ---------------------------------------------------------------------------
# Behavioral: a branch that is behind its base but merges cleanly is left
# untouched — HEAD unchanged, _SYNC_ISSUE_OUTCOME=current.
#
# Fixture shape:
#   main: A (README) → B (base-advance.txt, non-conflicting)
#                \
#   feature:      C (feature.txt, non-conflicting)
#
# merge-tree B←C exits 0 (clean), so sync_issue_branch must skip the rebase
# and return outcome=current.
# ---------------------------------------------------------------------------
@test "sync_issue_branch: behind-but-clean branch → outcome=current, HEAD unchanged" {
  # Skip if git does not support merge-tree --write-tree (requires git ≥ 2.38).
  # Must probe inside a real git repo — a bare tmpdir exits 128 regardless of version.
  git -C "$RITE_REPO_ROOT" merge-tree --write-tree HEAD HEAD >/dev/null 2>&1 || skip "git merge-tree --write-tree not supported"

  # ── Set up local git fixture ──────────────────────────────────────────────
  local BARE_REMOTE FIXTURE_REPO
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_WORKTREE_DIR="$FIXTURE_REPO/.rite/worktrees"
  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO" || return 1

  # Advance main with a non-conflicting commit
  git checkout main >/dev/null 2>&1
  echo "base advance" > base-advance.txt
  git add base-advance.txt
  git commit -m "Advance base (non-conflicting)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create feature branch from before the advance (one commit behind)
  local _feature_sha
  _feature_sha=$(git rev-parse HEAD~1)
  git checkout -b feat/issue-999 "$_feature_sha" >/dev/null 2>&1
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -m "Feature work (non-conflicting)" >/dev/null 2>&1
  git push -u origin feat/issue-999 >/dev/null 2>&1

  # Create a worktree for the feature branch
  local _wt="$RITE_WORKTREE_DIR/issue-999"
  git worktree add "$_wt" feat/issue-999 >/dev/null 2>&1

  # Record HEAD before sync so we can verify it did not change
  local _head_before
  _head_before=$(git -C "$_wt" rev-parse HEAD)

  # ── Write lock-dir cwd so sync_issue_branch finds the worktree ───────────
  mkdir -p "$RITE_LOCK_DIR/issue-999.lock"
  echo "$_wt" > "$RITE_LOCK_DIR/issue-999.lock/cwd"

  # ── Source integration-sync.sh and override dependency stubs ─────────────
  source "$RITE_LIB_DIR/utils/integration-sync.sh"
  set +u; set +o pipefail

  # Stubs defined AFTER source (function-sentinel guard: declare -f sync_integration_branch).
  # These are safe to override because integration-sync.sh is already loaded.
  get_locked_issue_numbers() { echo ""; }
  detect_pr_for_issue()      { return 1; }

  # resolve_target_branch must print "main" to stdout.
  resolve_target_branch() { echo "main"; }

  # ── Run the function ──────────────────────────────────────────────────────
  local _rc=0
  sync_issue_branch "999" || _rc=$?

  # ── Assertions ────────────────────────────────────────────────────────────
  # Exit 0 (composable skip counts as success)
  [ "$_rc" -eq 0 ]

  # Outcome is "current" — not "synced" (no rebase), not "conflict"
  [ "${_SYNC_ISSUE_OUTCOME:-}" = "current" ]

  # HEAD must be unchanged — branch was NOT rebased
  local _head_after
  _head_after=$(git -C "$_wt" rev-parse HEAD)
  [ "$_head_after" = "$_head_before" ]
}

# ---------------------------------------------------------------------------
# Behavioral: a rebase conflict invokes attempt_claude_merge_resolution in the
# parent shell so _RITE_RESOLVER_CONFLICT_PATHS propagates to
# commit_resolved_conflicts.  Scoped staging must NOT sweep untracked bystander
# files; _SYNC_ISSUE_OUTCOME must be "synced".
#
# Fixture shape:
#   main: A (README) → B (conflicting-file.txt = "base version")
#                \
#   feature:      C (conflicting-file.txt = "feature version")
#
# merge-tree B←C exits 1 (conflict), so the rebase path executes.
# The resolver stub writes the resolved content and exports
# _RITE_RESOLVER_CONFLICT_PATHS so commit_resolved_conflicts stages only that
# file, leaving the untracked bystander.txt out of the commit.
# ---------------------------------------------------------------------------
@test "sync_issue_branch: conflict resolver invoked in parent shell, bystander not committed, outcome=synced" {
  # Must probe inside a real git repo — a bare tmpdir exits 128 regardless of version.
  git -C "$RITE_REPO_ROOT" merge-tree --write-tree HEAD HEAD >/dev/null 2>&1 || skip "git merge-tree --write-tree not supported"

  # ── Set up local git fixture ──────────────────────────────────────────────
  local BARE_REMOTE FIXTURE_REPO
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_WORKTREE_DIR="$FIXTURE_REPO/.rite/worktrees"
  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO" || return 1

  # Advance main with a conflicting change to conflicting-file.txt
  git checkout main >/dev/null 2>&1
  echo "base version" > conflicting-file.txt
  git add conflicting-file.txt
  git commit -m "Base: set conflicting-file" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create feature branch from before the advance, with a conflicting edit
  local _base_sha
  _base_sha=$(git rev-parse HEAD~1)
  git checkout -b feat/issue-888 "$_base_sha" >/dev/null 2>&1
  echo "feature version" > conflicting-file.txt
  git add conflicting-file.txt
  git commit -m "Feature: set conflicting-file differently" >/dev/null 2>&1
  git push -u origin feat/issue-888 >/dev/null 2>&1

  # Create worktree for the feature branch
  local _wt="$RITE_WORKTREE_DIR/issue-888"
  git worktree add "$_wt" feat/issue-888 >/dev/null 2>&1

  # Add an untracked bystander file — must NOT end up in the resolution commit
  echo "bystander content" > "$_wt/bystander.txt"

  # Write lock-dir cwd so sync_issue_branch finds the worktree
  mkdir -p "$RITE_LOCK_DIR/issue-888.lock"
  echo "$_wt" > "$RITE_LOCK_DIR/issue-888.lock/cwd"

  # ── Source integration-sync.sh (also sources conflict-resolver.sh for
  #    commit_resolved_conflicts, since attempt_claude_merge_resolution is
  #    not yet defined when the source guard runs) ───────────────────────────
  source "$RITE_LIB_DIR/utils/integration-sync.sh"
  set +u; set +o pipefail

  # Stubs defined AFTER source (function-sentinel guard: declare -f sync_integration_branch)
  get_locked_issue_numbers() { echo ""; }
  detect_pr_for_issue()      { return 1; }
  resolve_target_branch()    { echo "main"; }

  # Stub attempt_claude_merge_resolution: simulate the resolver fixing the
  # conflict file and exporting the conflict paths for commit_resolved_conflicts.
  # Defined in the parent shell (not a subshell) so _RITE_RESOLVER_CONFLICT_PATHS
  # propagates — this is the invariant the fix guarantees.
  attempt_claude_merge_resolution() {
    echo "resolved by claude" > "$RITE_WORKTREE_DIR/issue-888/conflicting-file.txt"
    _RITE_RESOLVER_CONFLICT_PATHS="conflicting-file.txt"
    return 0
  }

  # ── Run sync_issue_branch ─────────────────────────────────────────────────
  local _rc=0
  sync_issue_branch "888" || _rc=$?

  # ── Assertions ────────────────────────────────────────────────────────────
  [ "$_rc" -eq 0 ]
  [ "${_SYNC_ISSUE_OUTCOME:-}" = "synced" ]

  # bystander.txt must NOT appear in the resolution commit
  local _last_commit_files
  _last_commit_files=$(git -C "$_wt" show --name-only --format="" HEAD 2>/dev/null || true)
  [[ "$_last_commit_files" != *"bystander.txt"* ]]

  # conflicting-file.txt MUST appear (was scoped-staged via _RITE_RESOLVER_CONFLICT_PATHS)
  [[ "$_last_commit_files" == *"conflicting-file.txt"* ]]
}
