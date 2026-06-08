#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/mid-run-rebase.sh, lib/utils/conflict-resolver.sh
# tests/regression/mid-run-rebase-conflict.bats
#
# Regression test: mid-run rebase aborts cleanly when main has content conflicts.
#
# Scenario: A wide-surface PR starts development while main is at SHA A.
# During phase 3 setup, a conflicting change lands on main (both the feature
# branch and main modified the same file with different content).
# The drift is BELOW the threshold (so auto-rebase is attempted), but the
# rebase has content conflicts.  check_and_rebase_against_main() must:
#   1. Attempt the rebase
#   2. Detect the conflict
#   3. Abort the rebase cleanly (no leftover rebase-merge state)
#   4. Print a clear message (not a silent die)
#   5. Return exit code 1 (workflow stops BEFORE generating a review)
#
# AC: "If the drift is above the threshold OR the rebase fails on content
#      conflicts, the workflow surfaces the situation early enough that the
#      Claude time spent in phase 3 isn't wasted."
# AC: "simulate main advancing with a content conflict — assert the workflow
#      aborts cleanly with a clear message, not after 77 min of phase-3 work."
#
# Issue: #200 (Prevent merge races in wide-surface refactor PRs)

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

  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Conflict path: rebase aborts cleanly, returns 1
# ---------------------------------------------------------------------------

@test "check_and_rebase_against_main: content conflict — aborts cleanly, returns 1" {
  local branch_name="fix/conflict-wide-surface-210"
  local issue_number="210"
  local pr_number="173"

  # Create feature branch that modifies shared.sh
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "# Feature version" > shared.sh
  echo "feature_function() { echo 'feature'; }" >> shared.sh
  git add shared.sh
  git commit -m "Wide-surface feature change to shared.sh" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Record the feature branch HEAD before the conflict is introduced
  local feature_head_before
  feature_head_before=$(git rev-parse HEAD)

  # Advance main with a CONFLICTING change to the same file (different content)
  git checkout main >/dev/null 2>&1
  echo "# Main version (conflict!)" > shared.sh
  echo "main_function() { echo 'main'; }" >> shared.sh
  git add shared.sh
  git commit -m "Main changes shared.sh — will conflict with feature branch" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-210"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify setup: branch is 1 commit behind main (below threshold, so rebase will be attempted)
  git -C "$worktree_path" fetch origin main >/dev/null 2>&1
  local behind
  behind=$(git -C "$worktree_path" rev-list --count \
    "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null)
  [ "$behind" -eq 1 ]

  # Run the check — should attempt rebase, detect conflict, abort cleanly, return 1
  # Use 'run' so bats captures the non-zero exit without failing the test
  run check_and_rebase_against_main "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "unsupervised"

  # AC: function returns 1 (abort, not continue)
  [ "$status" -eq 1 ]

  # AC: no leftover rebase state in worktree (rebase was cleanly aborted)
  local git_dir
  git_dir=$(git -C "$worktree_path" rev-parse --git-dir 2>/dev/null)
  [ ! -d "${git_dir}/rebase-merge" ]
  [ ! -d "${git_dir}/rebase-apply" ]

  # AC: branch HEAD is unchanged (rebase was aborted, not partially applied)
  local head_after
  head_after=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$head_after" = "$feature_head_before" ]

  # AC: shared.sh still contains the feature version (not the conflicting main version)
  local shared_content
  shared_content=$(cat "$worktree_path/shared.sh")
  [[ "$shared_content" =~ "feature_function" ]]
  [[ ! "$shared_content" =~ "main_function" ]]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: conflict message is informative (not silent die)" {
  # Verify the abort message is printed to stderr, not swallowed.
  # A silent die would be: script terminates with no output.
  # The message must mention conflict and how to resolve.
  local branch_name="fix/conflict-message-211"
  local issue_number="211"
  local pr_number="174"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "original content" > conflict-file.txt
  git add conflict-file.txt
  git commit -m "Feature adds conflict-file.txt" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Main also modifies the same file (conflict)
  git checkout main >/dev/null 2>&1
  echo "conflicting main content" > conflict-file.txt
  git add conflict-file.txt
  git commit -m "Main modifies conflict-file.txt" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-211"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Use 'run' to capture output and exit status together
  run check_and_rebase_against_main \
    "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "unsupervised"

  # AC: non-zero exit
  [ "$status" -eq 1 ]

  # AC: message contains actionable information (conflict and how to resolve)
  # 'output' in bats combines stdout+stderr from 'run'
  [[ "$output" =~ "conflict" ]] || [[ "$output" =~ "Conflict" ]]
  [[ "$output" =~ "rebase" ]] || [[ "$output" =~ "manually" ]]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: above-threshold message mentions drift count" {
  # When drift > threshold, the abort message must tell the user HOW far behind
  # they are (so they know whether to run supervised or wait for main to stabilize).
  local branch_name="fix/above-threshold-message-212"
  local issue_number="212"
  local pr_number="175"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main by 10 commits (well above default threshold 5)
  git checkout main >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "main $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-212"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Use 'run' to capture output and exit status
  run check_and_rebase_against_main \
    "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "unsupervised"

  # AC: abort (exit 1)
  [ "$status" -eq 1 ]

  # AC: message mentions the drift count (10)
  [[ "$output" =~ "10" ]]

  # AC: message mentions the threshold (5)
  [[ "$output" =~ "5" ]]

  # AC: message suggests supervised mode or manual rebase
  [[ "$output" =~ "supervised" ]] || [[ "$output" =~ "rebase" ]]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "check_and_rebase_against_main: missing worktree directory — returns 0 gracefully" {
  # If worktree was removed between phase 2 and phase 3 (crash scenario),
  # the function should not die but return 0 (fail open).
  check_and_rebase_against_main "/nonexistent/worktree" "fix/ghost-branch" "999" "99" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]
}

@test "check_and_rebase_against_main: fetch failure — skips check gracefully (returns 0)" {
  # Network partition during fetch: function must not block or die.
  # Simulate fetch failure by pointing origin to a non-existent URL.
  local branch_name="fix/fetch-fail-213"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1

  # Return to main before adding worktree (branch must not be checked out in parent repo)
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-213"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Override remote URL to something that will fail fetch
  git -C "$worktree_path" remote set-url origin "http://127.0.0.1:1/nonexistent" 2>/dev/null || true

  # Should return 0 (fail open — don't block workflow on network issues)
  check_and_rebase_against_main "$worktree_path" "$branch_name" "213" "77" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
}
