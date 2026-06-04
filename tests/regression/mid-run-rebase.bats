#!/usr/bin/env bats
# tests/regression/mid-run-rebase.bats
#
# Regression test: mid-run rebase fires when main advances during an active workflow.
#
# Scenario: A wide-surface PR (issue #200) starts development while main is at SHA A.
# During phase 3 setup (before assessment/review), several commits land on main (SHA B).
# The drift is BELOW the threshold (default 5), so check_and_rebase_against_main() must:
#   1. Detect the N-commit drift
#   2. Rebase the feature branch onto origin/main silently
#   3. Force-push with --force-with-lease
#   4. Return exit code 0 (workflow continues)
#
# AC: "A run that started while main was at SHA A and is now ready to merge with main at
#      SHA B (where B is N commits ahead of A) detects the drift before pre-merge validation."
# AC: "If the drift is below a threshold (default 5 commits), the workflow rebases
#      automatically between phase 3 and phase 4 — silently, with a one-line print_info."
#
# Issue: #200 (Prevent merge races in wide-surface refactor PRs)

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

  # Source the library under test
  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Core behavior: below-threshold drift gets auto-rebased
# ---------------------------------------------------------------------------

@test "check_and_rebase_against_main: drift 3 (below threshold 5) — rebase succeeds" {
  local branch_name="fix/wide-surface-issue-200"
  local issue_number="200"
  local pr_number="172"

  # Create feature branch with 2 commits simulating wide-surface work
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "wide change 1" > wide1.txt
  git add wide1.txt
  git commit -m "Wide change 1 for issue #200" >/dev/null 2>&1
  echo "wide change 2" > wide2.txt
  git add wide2.txt
  git commit -m "Wide change 2 for issue #200" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Simulate main advancing by 3 commits while the PR is in phase 3
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "main advance $i" > "main-advance-${i}.txt"
    git add "main-advance-${i}.txt"
    git commit -m "Main advance commit $i (while wide-surface PR was in flight)" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree simulating the active phase-3 context
  local worktree_path="$RITE_WORKTREE_DIR/issue-200"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify: branch is currently behind main
  git -C "$worktree_path" fetch origin main >/dev/null 2>&1
  local behind_before
  behind_before=$(git -C "$worktree_path" rev-list --count "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null)
  [ "$behind_before" -eq 3 ]

  # Run the check — should rebase silently (threshold default 5, drift is 3)
  check_and_rebase_against_main "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "unsupervised"
  local exit_code=$?

  # AC: function returns 0 (workflow continues)
  [ "$exit_code" -eq 0 ]

  # AC: branch now contains main's new files
  [ -f "$worktree_path/main-advance-1.txt" ]
  [ -f "$worktree_path/main-advance-2.txt" ]
  [ -f "$worktree_path/main-advance-3.txt" ]

  # AC: branch still has feature work
  [ -f "$worktree_path/wide1.txt" ]
  [ -f "$worktree_path/wide2.txt" ]

  # AC: branch is no longer behind main after rebase
  git -C "$worktree_path" fetch origin main >/dev/null 2>&1
  local behind_after
  behind_after=$(git -C "$worktree_path" rev-list --count "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null || echo "0")
  [ "${behind_after:-0}" -eq 0 ]

  # AC: no merge commits (rebase replays, doesn't merge)
  local merge_commits
  merge_commits=$(git -C "$worktree_path" log origin/main..HEAD --merges --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$merge_commits" -eq 0 ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: drift 0 — returns 0 without fetching or rebasing" {
  local branch_name="fix/no-drift-issue-201"

  # Create feature branch — main does NOT advance
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Return to main so the branch is not checked out here (git worktree add
  # requires the branch to not be checked out in the requesting repo)
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-201"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Run check — branch is current, should be a no-op
  check_and_rebase_against_main "$worktree_path" "$branch_name" "201" "99" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Branch is still at original HEAD (no rebase happened)
  local head_after
  head_after=$(git -C "$worktree_path" rev-parse HEAD)
  local original_head
  original_head=$(git -C "$FIXTURE_REPO" rev-parse "$branch_name")
  [ "$head_after" = "$original_head" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: drift exactly at threshold — auto-rebases (threshold is inclusive lower bound)" {
  # Threshold default is 5.  Drift == 5 should rebase (<=), not abort (>).
  local branch_name="fix/at-threshold-202"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main by exactly 5 commits
  git checkout main >/dev/null 2>&1
  for i in 1 2 3 4 5; do
    echo "main $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-202"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Default threshold is 5 — drift == 5 should trigger rebase, not abort
  check_and_rebase_against_main "$worktree_path" "$branch_name" "202" "88" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Main's 5 new files should now be present on the feature branch
  [ -f "$worktree_path/main-1.txt" ]
  [ -f "$worktree_path/main-5.txt" ]
  [ -f "$worktree_path/feature.txt" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: drift above threshold — returns 1 (abort before review)" {
  # Drift 7 > threshold 5: should abort early with a clear message, not attempt rebase
  local branch_name="fix/above-threshold-203"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main by 7 commits (above threshold of 5)
  git checkout main >/dev/null 2>&1
  for i in $(seq 1 7); do
    echo "main $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-203"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Should return 1 (abort) without rebasing
  local original_head
  original_head=$(git -C "$worktree_path" rev-parse HEAD)

  # Use 'run' so bats captures the non-zero exit without failing the test
  run check_and_rebase_against_main "$worktree_path" "$branch_name" "203" "89" "unsupervised"

  # AC: abort (exit 1), not silently continue
  [ "$status" -eq 1 ]

  # AC: branch NOT modified (no rebase attempted)
  local head_after
  head_after=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$head_after" = "$original_head" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: custom threshold (RITE_MID_RUN_REBASE_THRESHOLD=10)" {
  # With a custom threshold of 10, drift of 8 should rebase, not abort
  local branch_name="fix/custom-threshold-204"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main by 8 commits (above default threshold 5, but below custom 10)
  git checkout main >/dev/null 2>&1
  for i in $(seq 1 8); do
    echo "main $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-204"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # With custom threshold 10, drift 8 is below threshold — should rebase
  RITE_MID_RUN_REBASE_THRESHOLD=10 \
    check_and_rebase_against_main "$worktree_path" "$branch_name" "204" "90" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Main's 8 new files are present on the feature branch
  [ -f "$worktree_path/main-1.txt" ]
  [ -f "$worktree_path/main-8.txt" ]
  [ -f "$worktree_path/feature.txt" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: backup ref created before rebase" {
  # The DO NOT bullet says: do NOT rebase published commits without preserving
  # original SHAs in a backup ref.  Verify refs/rite-rebase-backup/* is written.
  local branch_name="fix/backup-ref-205"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Record pre-rebase HEAD
  local pre_rebase_head
  pre_rebase_head=$(git rev-parse "$branch_name")

  # Advance main by 3 commits
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "main $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-205"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  check_and_rebase_against_main "$worktree_path" "$branch_name" "205" "91" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Verify a backup ref pointing to the pre-rebase commit was created
  # Backup refs are at refs/rite-rebase-backup/<branch>/<timestamp>
  local backup_refs
  backup_refs=$(git -C "$worktree_path" for-each-ref --format='%(refname)' "refs/rite-rebase-backup/${branch_name}/*" 2>/dev/null || true)
  [ -n "$backup_refs" ]

  # Verify the backup ref points to the original pre-rebase HEAD
  local backup_sha
  backup_sha=$(git -C "$worktree_path" rev-parse "$(echo "$backup_refs" | head -1)" 2>/dev/null || true)
  [ "$backup_sha" = "$pre_rebase_head" ]

  # Cleanup
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_and_rebase_against_main: non-feature branches (main) are skipped" {
  # Sanity: function must be a no-op for main branch itself (guard against infinite loop)
  local worktree_path="$RITE_WORKTREE_DIR/main-wt"
  mkdir -p "$worktree_path"

  # Simulate being on main (branch_name = "main")
  check_and_rebase_against_main "$FIXTURE_REPO" "main" "999" "99" "unsupervised"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]
}
