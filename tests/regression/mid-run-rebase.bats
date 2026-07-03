#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/mid-run-rebase.sh
# tests/regression/mid-run-rebase.bats
#
# Regression test: mid-run rebase fires when main advances during an active workflow.
#
# Scenario: A wide-surface PR (issue #200) starts development while main is at SHA A.
# During phase 3 setup (before assessment/review), several commits land on main (SHA B).
# As long as the rebase applies cleanly, check_and_rebase_against_main() must:
#   1. Detect the N-commit drift (any N > 0)
#   2. Rebase the feature branch onto origin/main silently
#   3. Force-push with --force-with-lease
#   4. Return exit code 0 (workflow continues)
#
# Commit distance is NOT a gate: a clean rebase is cheap regardless of how far behind the
# branch is, so a far-behind-but-clean branch must rebase, not abort.  Only a genuine
# content conflict aborts (covered in mid-run-rebase-conflict.bats).
#
# AC: "A run that started while main was at SHA A and is now ready to merge with main at
#      SHA B (where B is N commits ahead of A) detects the drift before pre-merge validation."
#
# Issue: #200 (Prevent merge races in wide-surface refactor PRs)
# Redesign: false-abort on clean far-behind branches removed (#433/#439 incident).

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
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Core behavior: clean drift is a NO-OP — the branch is left untouched.
# A behind-but-clean branch merges fine in phase 4; rebasing it would only churn
# history and re-trigger the post-commit test gate.  Only a real conflict acts
# (covered in mid-run-rebase-conflict.bats).
# ---------------------------------------------------------------------------

@test "check_and_rebase_against_main: drift 3 (clean) — no-op, branch untouched" {
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

  # Simulate main advancing by 3 NON-conflicting commits while the PR is in phase 3
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
  local behind_before head_before
  behind_before=$(git -C "$worktree_path" rev-list --count "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null)
  head_before=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$behind_before" -eq 3 ]

  # Run the check — branch merges cleanly, so this is a no-op
  check_and_rebase_against_main "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "unsupervised"
  local exit_code=$?

  # AC: function returns 0 (workflow continues)
  [ "$exit_code" -eq 0 ]

  # AC: branch HEAD is UNCHANGED — no rebase, no force-push, no gate churn
  local head_after
  head_after=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$head_after" = "$head_before" ]

  # AC: main's new files were NOT pulled into the branch (it was left alone)
  [ ! -f "$worktree_path/main-advance-1.txt" ]
  [ ! -f "$worktree_path/main-advance-3.txt" ]

  # AC: feature work is intact
  [ -f "$worktree_path/wide1.txt" ]
  [ -f "$worktree_path/wide2.txt" ]

  # AC: branch is STILL behind main (we intentionally did not advance it)
  git -C "$worktree_path" fetch origin main >/dev/null 2>&1
  local behind_after
  behind_after=$(git -C "$worktree_path" rev-list --count "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null || echo "0")
  [ "${behind_after:-0}" -eq 3 ]

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

@test "check_and_rebase_against_main: far behind but clean (drift 12) — no-op, returns 0" {
  # Regression for the #433/#439 incident: two PRs ~12 commits behind main with
  # ZERO conflicting files were falsely aborted by the old count-based threshold,
  # wasting two LLM reviews.  A clean branch must be left alone (no rebase, no abort)
  # regardless of how far behind it is — phase 4 merges it as-is.
  local branch_name="fix/far-behind-clean-203"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main by 12 NON-conflicting commits (each touches a distinct new file)
  git checkout main >/dev/null 2>&1
  for i in $(seq 1 12); do
    echo "main $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-203"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Confirm setup: branch is genuinely 12 commits behind
  git -C "$worktree_path" fetch origin main >/dev/null 2>&1
  local behind_before head_before
  behind_before=$(git -C "$worktree_path" rev-list --count \
    "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null)
  head_before=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$behind_before" -eq 12 ]

  # Distance is not a gate: a clean branch returns 0 without being touched
  check_and_rebase_against_main "$worktree_path" "$branch_name" "203" "89" "unsupervised"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  # AC: HEAD unchanged — no rebase, no force-push, no gate churn on a clean branch
  local head_after
  head_after=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$head_after" = "$head_before" ]

  # AC: main's files were NOT pulled in; the branch is still 12 behind
  [ ! -f "$worktree_path/main-1.txt" ]
  [ ! -f "$worktree_path/main-12.txt" ]
  [ -f "$worktree_path/feature.txt" ]
  git -C "$worktree_path" fetch origin main >/dev/null 2>&1
  local behind_after
  behind_after=$(git -C "$worktree_path" rev-list --count \
    "$(git -C "$worktree_path" merge-base HEAD origin/main)..origin/main" 2>/dev/null || echo "0")
  [ "${behind_after:-0}" -eq 12 ]

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
