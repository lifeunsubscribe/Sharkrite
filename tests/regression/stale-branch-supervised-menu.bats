#!/usr/bin/env bats
# tests/regression/stale-branch-supervised-menu.bats
#
# Regression tests for issue #165: Supervised mode does not offer interactive options
#
# Verifies that _stale_classify_after_push_rejection() offers interactive menus in
# supervised mode for RELATED and UNRELATED foreign commit classifications — consistent
# with divergence-handler.sh's _handle_related() and _handle_unrelated() menus.
#
# Test matrix:
#   RELATED  + supervised + choice 'a' → rebase + push → exit 2 (re-enter review)
#   RELATED  + supervised + choice 'b' → rebase + push → exit 0 (no re-review)
#   RELATED  + supervised + choice 'c' → force-push → exit 0
#   RELATED  + supervised + choice 'd' → abort → exit 1
#   UNRELATED + supervised + choice 'c' → force-push → exit 0
#   UNRELATED + supervised + choice 'd' → abort → exit 1
#   RELATED  + auto      → rebase + push → exit 2 (unchanged: no menu)
#   UNRELATED + auto     → rebase + push → exit 2 (unchanged: no menu)

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

  # Source the stale-branch library
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared helper: sets up a push-race scenario.
#
# After this call:
#   - BRANCH_NAME is set to the feature branch name
#   - WORKTREE_PATH is set to a worktree on the feature branch
#   - The remote has a concurrent foreign commit that will cause push rejection
#   - classify_foreign_commits is stubbed to return the given classification
#   - verify_post_merge is stubbed to always pass
#
# Usage: _setup_push_race_scenario "RELATED"|"UNRELATED"
# ─────────────────────────────────────────────────────────────────────────────
_setup_push_race_scenario() {
  local classification="$1"

  BRANCH_NAME="fix/supervised-menu-test-165-$$"

  # Feature branch with one commit, pushed
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "feature work" > feature-165.txt
  git add feature-165.txt
  git commit -m "Feature work for supervised menu test" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Diverge main so stale-branch has rebase work
  git checkout main >/dev/null 2>&1
  echo "main divergence" > main-165.txt
  git add main-165.txt
  git commit -m "Main divergence for supervised menu test" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout "$BRANCH_NAME" >/dev/null 2>&1

  # Create worktree
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-165-supervised-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  # Concurrent push: another client pushes to the same branch while we rebase,
  # causing our --force-with-lease to be rejected.
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-165-$$"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Concurrent Client" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "foreign change from concurrent client" > "$concurrent_dir/foreign-165.txt"
  git -C "$concurrent_dir" add foreign-165.txt >/dev/null 2>&1
  git -C "$concurrent_dir" commit -m "fix: foreign change for supervised menu test" >/dev/null 2>&1
  git -C "$concurrent_dir" push origin "$BRANCH_NAME" >/dev/null 2>&1

  # Write stub scripts that can be sourced in sub-shell test invocations.
  # classify_foreign_commits is stubbed to return the requested classification.
  # Using files avoids single-quote escaping issues in bash -c invocations.
  export STUB_CLASSIFICATION="$classification"
  export STUB_DIR="$RITE_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/stubs.sh" <<'STUBS_EOF'
classify_foreign_commits() {
  export DIVERGENCE_CLASS="${STUB_CLASSIFICATION:-RELATED}"
  return 0
}
verify_post_merge() { return 0; }
STUBS_EOF
}

_cleanup_push_race_scenario() {
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# Helper: run _stale_rebase_onto_main in a subshell with the given user input
# Usage: _run_rebase_with_input CHOICE WORKFLOW_MODE CLASSIFICATION
_run_rebase_with_input() {
  local choice="$1"
  local workflow_mode="$2"
  local classification="$3"
  export STUB_CLASSIFICATION="$classification"

  # Pipe choice as stdin to the subshell so read -p captures it
  echo "$choice" | bash -s -- \
    "$RITE_LIB_DIR" "$STUB_DIR" "$WORKTREE_PATH" "$BRANCH_NAME" "$workflow_mode" \
    <<'RUNNER_EOF'
  RITE_LIB_DIR="$1"
  STUB_DIR="$2"
  WORKTREE_PATH="$3"
  BRANCH_NAME="$4"
  WORKFLOW_MODE="$5"

  # Bring environment variables into scope for stale-branch.sh
  export RITE_LIB_DIR WORKTREE_PATH BRANCH_NAME WORKFLOW_MODE

  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  source "$STUB_DIR/stubs.sh"

  _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "$WORKFLOW_MODE" "165" "99"
RUNNER_EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# RELATED supervised: choice 'a' → pull + re-enter review cycle (exit 2)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised RELATED choice 'a': pull + re-enter review cycle returns exit 2" {
  _setup_push_race_scenario "RELATED"

  run _run_rebase_with_input "a" "supervised" "RELATED"

  # Must return exit 2: re-enter review cycle
  [ "$status" -eq 2 ]

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# RELATED supervised: choice 'b' → pull without review (exit 0)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised RELATED choice 'b': pull without review returns exit 0" {
  _setup_push_race_scenario "RELATED"

  run _run_rebase_with_input "b" "supervised" "RELATED"

  # Must return exit 0: continue workflow, no re-review needed
  [ "$status" -eq 0 ]

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# RELATED supervised: choice 'c' → force-push (discard foreign commits, exit 0)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised RELATED choice 'c': force-push discards foreign commits and returns exit 0" {
  _setup_push_race_scenario "RELATED"

  run _run_rebase_with_input "c" "supervised" "RELATED"

  # Must return exit 0: force-push succeeded
  [ "$status" -eq 0 ]

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# RELATED supervised: choice 'd' → abort (exit 1)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised RELATED choice 'd': abort returns exit 1" {
  _setup_push_race_scenario "RELATED"

  run _run_rebase_with_input "d" "supervised" "RELATED"

  # Must return exit 1: user aborted
  [ "$status" -eq 1 ]

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# UNRELATED supervised: choice 'c' → force-push (exit 0)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised UNRELATED choice 'c': force-push discards foreign commits and returns exit 0" {
  _setup_push_race_scenario "UNRELATED"

  run _run_rebase_with_input "c" "supervised" "UNRELATED"

  # Must return exit 0: force-push succeeded
  [ "$status" -eq 0 ]

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# UNRELATED supervised: choice 'd' → abort (exit 1)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised UNRELATED choice 'd': abort returns exit 1" {
  _setup_push_race_scenario "UNRELATED"

  run _run_rebase_with_input "d" "supervised" "UNRELATED"

  # Must return exit 1: user aborted
  [ "$status" -eq 1 ]

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# UNRELATED supervised: menu output mentions 'c' and 'd' options but NOT 'a' or 'b'
# (unrelated foreign commits should not offer a "pull" option)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised UNRELATED: menu offers only 'c' and 'd' options (not 'a' or 'b')" {
  _setup_push_race_scenario "UNRELATED"

  run _run_rebase_with_input "d" "supervised" "UNRELATED"

  # Output should mention 'c' and 'd' options
  echo "$output" | grep -qi "Overwrite remote"
  echo "$output" | grep -qi "Abort"

  # Output must NOT offer 'a' or 'b' options (those are RELATED-only)
  ! echo "$output" | grep -qi "Pull and re-enter review"
  ! echo "$output" | grep -qi "Pull without review"

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# RELATED supervised: menu output mentions all four options (a, b, c, d)
# ─────────────────────────────────────────────────────────────────────────────
@test "supervised RELATED: menu offers all four options (a, b, c, d)" {
  _setup_push_race_scenario "RELATED"

  run _run_rebase_with_input "d" "supervised" "RELATED"

  # Output should mention all options
  echo "$output" | grep -qi "Pull and re-enter review"
  echo "$output" | grep -qi "Pull without review"
  echo "$output" | grep -qi "Overwrite remote"
  echo "$output" | grep -qi "Abort"

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto mode: RELATED foreign commits are still integrated and return exit 2
# (regression guard: auto mode must NOT be affected by supervised menu changes)
# ─────────────────────────────────────────────────────────────────────────────
@test "auto mode RELATED: no menu shown, integrates and returns exit 2 (unchanged)" {
  _setup_push_race_scenario "RELATED"

  run _run_rebase_with_input "" "auto" "RELATED"

  # Auto mode: must return exit 2 (re-review needed) without any prompt
  [ "$status" -eq 2 ]

  # No interactive menu output
  ! echo "$output" | grep -qiE "Choose \[a/b/c/d\]"

  _cleanup_push_race_scenario
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto mode: UNRELATED foreign commits are integrated and return exit 2
# (regression guard: auto mode must NOT be affected by supervised menu changes)
# ─────────────────────────────────────────────────────────────────────────────
@test "auto mode UNRELATED: no menu shown, integrates and returns exit 2 (unchanged)" {
  _setup_push_race_scenario "UNRELATED"

  run _run_rebase_with_input "" "auto" "UNRELATED"

  # Auto mode: must return exit 2 (re-review needed) without any prompt
  [ "$status" -eq 2 ]

  # No interactive menu output
  ! echo "$output" | grep -qiE "Choose \[c/d\]"

  _cleanup_push_race_scenario
}
