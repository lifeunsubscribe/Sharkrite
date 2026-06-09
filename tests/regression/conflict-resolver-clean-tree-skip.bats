#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/mid-run-rebase.sh, lib/utils/stale-branch.sh, lib/utils/divergence-handler.sh, lib/utils/conflict-resolver.sh
# tests/regression/conflict-resolver-clean-tree-skip.bats
#
# Regression test: post-resolution commit step must be skipped when the tree is
# already clean (the resolver's internal `git merge --no-edit` auto-committed).
#
# Root cause: PR #435 (issue #432) added an unconditional `git commit --no-edit`
# between conflict resolution and `git push --force-with-lease`. When the rebase
# auto-resolves or the resolver's merge commits cleanly, the working tree is
# already clean by the time the new commit fires. `git commit` exits non-zero
# ("nothing to commit"), and the calling code interpreted that as resolution
# failure — aborting the entire workflow.
#
# Live failure: issue #360, 2026-06-07. The branch was ahead by 2 commits (merge
# already committed cleanly), tree clean, but the unconditional commit step
# failed and Phase 3 was aborted.
#
# Fix: guard each `git commit --no-edit` with `[ -n "$(git status --porcelain)" ]`
# at all four call sites in:
#   - lib/utils/mid-run-rebase.sh    (the new path added by #432)
#   - lib/utils/stale-branch.sh      (rebase path)
#   - lib/utils/stale-branch.sh      (merge path)
#   - lib/utils/divergence-handler.sh

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  # Standard environment
  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"

  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO"
}

teardown() {
  teardown_test_tmpdir
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────────────

# Set up a feature branch and worktree with a conflict against main.
# After this call BRANCH_NAME, WORKTREE_PATH, and FEATURE_HEAD are set.
_setup_conflict_branch() {
  BRANCH_NAME="fix/clean-tree-test-$$"

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "Feature line" >> README.md
  git add README.md
  git commit -m "Feature: change README" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  FEATURE_HEAD=$(git rev-parse HEAD)

  # Advance main with a conflicting change
  git checkout main >/dev/null 2>&1
  echo "Main line (conflict)" >> README.md
  git add README.md
  git commit -m "Main: change README (conflict)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree on feature branch
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-clean-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
  cd "$WORKTREE_PATH"
}

_cleanup_branch() {
  cd "$FIXTURE_REPO"
  git worktree remove "${WORKTREE_PATH:-}" --force >/dev/null 2>&1 || true
  git branch -D "${BRANCH_NAME:-}" >/dev/null 2>&1 || true
  git push origin --delete "${BRANCH_NAME:-}" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# mid-run-rebase.sh — the live failure site (issue #360)
# ─────────────────────────────────────────────────────────────────────────────

@test "mid-run-rebase: clean tree after resolver — skips commit, push succeeds (issue #360)" {
  # Regression test for the live failure: resolver's merge auto-committed, tree
  # was clean, unconditional `git commit --no-edit` exited non-zero, Phase 3 aborted.
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  _setup_conflict_branch

  # Stub: resolver "resolves" by producing a clean commit (no staged files left).
  # This mirrors what happens when git merge --no-edit succeeds without conflicts:
  # the merge is auto-committed and the working tree is clean.
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Feature line" > README.md
    echo "Main line (conflict)" >> README.md
    git add README.md
    git commit -m "chore: resolve via Claude (auto-committed, clean tree)" >/dev/null 2>&1
    # Tree is now clean — this is the scenario that triggered issue #360
    return 0
  }

  # Invoke the post-resolution path inside check_and_rebase_against_main.
  # Should NOT print "failed to commit resolved conflicts" and should return 0.
  local output exit_code=0
  output=$(check_and_rebase_against_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "360" "435" "unsupervised" 2>&1) || exit_code=$?

  # Must succeed
  [ "$exit_code" -eq 0 ]

  # Must NOT contain the failure message that caused issue #360
  ! echo "$output" | grep -q "failed to commit resolved conflicts"

  # Push must have run (remote HEAD matches local HEAD)
  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "mid-run-rebase: dirty tree after resolver — commit fires, push succeeds (preserves #432 fix)" {
  # Regression guard for the original #432 fix: when the resolver leaves a pending
  # merge with staged conflicts resolved (the normal conflict-resolution path), the
  # commit step MUST fire.
  #
  # The real conflict-resolver.sh works by calling `git merge origin/main --no-edit`
  # which fails with conflicts (MERGE_HEAD is set), then Claude resolves the conflicts
  # and stages them. The outer code commits with `--no-edit` using the MERGE_HEAD
  # message. We simulate this by having the stub initiate a merge with --no-commit,
  # resolve the conflict, and stage it — leaving MERGE_HEAD + staged files (dirty tree).
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  _setup_conflict_branch

  # Stub: simulates the real resolver contract — staged files with MERGE_HEAD pending.
  # Uses --no-commit to leave the merge uncommitted (resolver's job ends at staging).
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    git fetch origin main >/dev/null 2>&1 || true
    # Start merge with --no-commit to get MERGE_HEAD state (mimics resolver's internal merge)
    git merge origin/main --no-commit --no-edit >/dev/null 2>&1 || true
    # Resolve the conflict by writing the merged content and staging it
    echo "Feature line" > README.md
    echo "Main line (resolved)" >> README.md
    git add README.md
    # Return 0 with MERGE_HEAD set and files staged (pending merge, not committed)
    return 0
  }

  local output exit_code=0
  output=$(check_and_rebase_against_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "432" "435" "unsupervised" 2>&1) || exit_code=$?

  # Must succeed
  [ "$exit_code" -eq 0 ]

  # The commit step must have run (push succeeded, remote matches local)
  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "mid-run-rebase: resolver failure — returns non-zero, no commit/push attempted" {
  # Guard: when the resolver returns 1, the code must bail immediately — no
  # commit or push should fire.
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  _setup_conflict_branch

  # Stub: resolver fails
  attempt_claude_merge_resolution() {
    return 1
  }

  local output exit_code=0
  output=$(check_and_rebase_against_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "999" "999" "unsupervised" 2>&1) || exit_code=$?

  # Must fail
  [ "$exit_code" -ne 0 ]

  # Remote must NOT have advanced (no push fired)
  local remote_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local feature_head="$FEATURE_HEAD"
  [ "$remote_sha" = "$feature_head" ]

  _cleanup_branch
}

# ─────────────────────────────────────────────────────────────────────────────
# stale-branch.sh — rebase path (_stale_rebase_onto_main)
# ─────────────────────────────────────────────────────────────────────────────

@test "stale-branch rebase path: clean tree after resolver — skips commit, push succeeds" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  _setup_conflict_branch

  # Stub: resolver auto-commits (clean tree on return)
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Resolved content" > README.md
    git add README.md
    git commit -m "chore: resolve via Claude (clean tree)" >/dev/null 2>&1
    return 0
  }

  # _stale_rebase_onto_main args: worktree_path branch_name workflow_mode issue_number pr_number
  local output exit_code=0
  output=$(_stale_rebase_onto_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "360" "435" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]
  ! echo "$output" | grep -q "failed to commit resolved conflicts"
  ! echo "$output" | grep -q "Failed to commit resolved conflicts"

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "stale-branch rebase path: dirty tree after resolver — commit fires, push succeeds" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  _setup_conflict_branch

  # Stub: simulates real resolver contract — pending merge with staged conflicts resolved.
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    git fetch origin main >/dev/null 2>&1 || true
    git merge origin/main --no-commit --no-edit >/dev/null 2>&1 || true
    echo "Resolved content" > README.md
    git add README.md
    # Pending merge + staged files (not committed)
    return 0
  }

  local output exit_code=0
  output=$(_stale_rebase_onto_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "432" "435" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

# ─────────────────────────────────────────────────────────────────────────────
# stale-branch.sh — legacy-merge path (_stale_merge_main_legacy)
# ─────────────────────────────────────────────────────────────────────────────

@test "stale-branch legacy-merge path: clean tree after resolver — skips commit, push succeeds" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  _setup_conflict_branch

  # Stub: resolver auto-commits (clean tree on return)
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Resolved content" > README.md
    git add README.md
    git commit -m "chore: resolve via Claude (legacy-merge path, clean tree)" >/dev/null 2>&1
    return 0
  }

  # _stale_merge_main_legacy args: worktree_path branch_name workflow_mode issue_number pr_number
  local output exit_code=0
  output=$(_stale_merge_main_legacy \
    "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "360" "435" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]
  ! echo "$output" | grep -q "Failed to commit resolved conflicts"

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "stale-branch legacy-merge path: dirty tree after resolver — commit fires, push succeeds" {
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  _setup_conflict_branch

  # Stub: simulates real resolver contract — pending merge with staged conflicts resolved.
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    git fetch origin main >/dev/null 2>&1 || true
    git merge origin/main --no-commit --no-edit >/dev/null 2>&1 || true
    echo "Resolved content" > README.md
    git add README.md
    # Pending merge + staged files (not committed)
    return 0
  }

  local output exit_code=0
  output=$(_stale_merge_main_legacy \
    "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "432" "435" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

# ─────────────────────────────────────────────────────────────────────────────
# divergence-handler.sh — _do_rebase_and_push
# ─────────────────────────────────────────────────────────────────────────────

@test "divergence-handler: clean tree after resolver — skips commit, falls through to push" {
  # Set up a diverging branch (local and remote have diverged on same file)
  BRANCH_NAME="fix/diverge-clean-$$"

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "# Feature: shared base" > README.md
  git add README.md
  git commit -m "Feature: shared base" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Remote side: add a commit on origin/BRANCH_NAME
  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Test User"
  git -C "$tmp_clone" config user.email "test@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "# Feature: remote-specific content" > "$tmp_clone/README.md"
  git -C "$tmp_clone" add README.md
  git -C "$tmp_clone" commit -m "Remote conflicting change" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1

  # Local side: add a conflicting commit (not pushed)
  echo "# Feature: local-specific content" > README.md
  git add README.md
  git commit -m "Local conflicting change (not pushed)" >/dev/null 2>&1

  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-diverge-clean-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
  cd "$WORKTREE_PATH"

  # Fetch so divergence handler can detect the divergence
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  source "$RITE_LIB_DIR/utils/divergence-handler.sh"

  # Stub: resolver auto-commits (clean tree on return)
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "# Feature: merged content" > README.md
    git add README.md
    git commit -m "chore: resolve divergence via Claude (clean tree)" >/dev/null 2>&1
    return 0
  }

  local output exit_code=0
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "360" "435" 2>&1) || exit_code=$?

  # Must succeed
  [ "$exit_code" -eq 0 ]

  # Must NOT contain the failure message
  ! echo "$output" | grep -q "Failed to commit resolved conflicts"

  # Push must have run
  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

@test "divergence-handler: dirty tree after resolver — commit fires, falls through to push" {
  # Same divergence setup but resolver stages only (dirty tree — commit must fire)
  BRANCH_NAME="fix/diverge-dirty-$$"

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "# Feature: shared base" > README.md
  git add README.md
  git commit -m "Feature: shared base" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-dirty-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Test User"
  git -C "$tmp_clone" config user.email "test@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "# Feature: remote-specific" > "$tmp_clone/README.md"
  git -C "$tmp_clone" add README.md
  git -C "$tmp_clone" commit -m "Remote change" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1

  echo "# Feature: local-specific" > README.md
  git add README.md
  git commit -m "Local change (not pushed)" >/dev/null 2>&1

  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-diverge-dirty-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
  cd "$WORKTREE_PATH"

  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  source "$RITE_LIB_DIR/utils/divergence-handler.sh"

  # Stub: simulates real resolver contract — pending merge with staged conflicts resolved.
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    git fetch origin "$BRANCH_NAME" >/dev/null 2>&1 || true
    git merge "origin/$BRANCH_NAME" --no-commit --no-edit >/dev/null 2>&1 || true
    echo "# Feature: merged content" > README.md
    git add README.md
    # Pending merge + staged files (not committed)
    return 0
  }

  local output exit_code=0
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "432" "435" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Broader git status check narrowed to staged-only (issue #429-434)
#
# git status --porcelain is broader than the staged-resolution condition:
# it also returns output for untracked files (??) and unstaged changes ( M).
# Neither of those is included by `git commit --no-edit`, so checking them
# would spuriously trigger a failing commit attempt.
#
# Fix: use `! git diff --cached --quiet` instead — checks only the index.
# ─────────────────────────────────────────────────────────────────────────────

@test "mid-run-rebase: resolver with untracked files only — skips commit, push succeeds" {
  # Regression: `git status --porcelain` fires for untracked files (??), but
  # `git commit --no-edit` won't include them. With the old broad check the commit
  # would run and fail ("nothing to commit"). With the new index-only check
  # (`git diff --cached --quiet`) untracked files are invisible to the guard
  # and the commit is correctly skipped.
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"

  _setup_conflict_branch

  # Stub: resolver auto-commits resolution AND leaves a stray untracked file.
  # The stray file makes `git status --porcelain` non-empty (would wrongly trigger
  # commit with old check), but the index is clean (new check must skip commit).
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Feature line" > README.md
    echo "Main line (conflict)" >> README.md
    git add README.md
    git commit -m "chore: resolve via Claude (untracked-file test)" >/dev/null 2>&1
    # Leave an untracked file — makes git status --porcelain non-empty
    echo "stray" > untracked-stray.tmp
    return 0
  }

  local output exit_code=0
  output=$(check_and_rebase_against_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "429" "458" "unsupervised" 2>&1) || exit_code=$?

  # Must succeed (untracked file must not trigger a spurious commit failure)
  [ "$exit_code" -eq 0 ]

  # Must NOT contain a commit-failure message
  ! echo "$output" | grep -q "failed to commit resolved conflicts"

  # Remote must be up to date (push ran)
  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "stale-branch rebase path: resolver with untracked files only — skips commit, push succeeds" {
  # Same scenario as above, covering the _stale_rebase_onto_main code path.
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  _setup_conflict_branch

  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Resolved content" > README.md
    git add README.md
    git commit -m "chore: resolve (untracked-file test, rebase path)" >/dev/null 2>&1
    echo "stray" > untracked-stray.tmp
    return 0
  }

  local output exit_code=0
  output=$(_stale_rebase_onto_main \
    "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "429" "458" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]
  ! echo "$output" | grep -q "Failed to commit resolved conflicts"

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "stale-branch legacy-merge path: resolver with untracked files only — skips commit, push succeeds" {
  # Same scenario, covering the _stale_merge_main_legacy code path.
  source "$RITE_LIB_DIR/utils/stale-branch.sh"

  _setup_conflict_branch

  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "Resolved content" > README.md
    git add README.md
    git commit -m "chore: resolve (untracked-file test, legacy-merge path)" >/dev/null 2>&1
    echo "stray" > untracked-stray.tmp
    return 0
  }

  local output exit_code=0
  output=$(_stale_merge_main_legacy \
    "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "429" "458" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]
  ! echo "$output" | grep -q "Failed to commit resolved conflicts"

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  _cleanup_branch
}

@test "divergence-handler: resolver with untracked files only — skips commit, falls through to push" {
  # Same scenario, covering the _do_rebase_and_push code path in divergence-handler.sh.
  BRANCH_NAME="fix/diverge-untracked-$$"

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "# Feature: shared base" > README.md
  git add README.md
  git commit -m "Feature: shared base" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-untracked-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Test User"
  git -C "$tmp_clone" config user.email "test@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "# Feature: remote-specific" > "$tmp_clone/README.md"
  git -C "$tmp_clone" add README.md
  git -C "$tmp_clone" commit -m "Remote conflicting change" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1

  echo "# Feature: local-specific" > README.md
  git add README.md
  git commit -m "Local conflicting change (not pushed)" >/dev/null 2>&1

  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-diverge-untracked-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
  cd "$WORKTREE_PATH"

  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  source "$RITE_LIB_DIR/utils/divergence-handler.sh"

  # Stub: resolver auto-commits AND leaves a stray untracked file.
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    echo "# Feature: merged content" > README.md
    git add README.md
    git commit -m "chore: resolve divergence (untracked-file test)" >/dev/null 2>&1
    echo "stray" > untracked-stray.tmp
    return 0
  }

  local output exit_code=0
  output=$(_do_rebase_and_push "$BRANCH_NAME" "true" "429" "458" 2>&1) || exit_code=$?

  [ "$exit_code" -eq 0 ]
  ! echo "$output" | grep -q "Failed to commit resolved conflicts"

  local remote_sha local_sha
  remote_sha=$(git -C "$WORKTREE_PATH" rev-parse "origin/$BRANCH_NAME" 2>/dev/null || true)
  local_sha=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
  [ "$remote_sha" = "$local_sha" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}
