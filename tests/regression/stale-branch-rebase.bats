#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh
# tests/regression/stale-branch-rebase.bats - Stale branch rebase tests
#
# Tests that stale branches are brought up to date via rebase (not merge).
# Verifies fixes for issue #74 (rebase stale branches instead of merging main).

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  # Pin the LEGACY resolver/abort path: #855's small-branch fast-path (auto-mode
  # conflicts on <=RITE_REBASE_CONFLICT_RESTART_MAX work commits restart fresh)
  # would preempt the conflict-resolution contracts these tests pin. 0 disables
  # the fast-path; the restart contract is covered by stale-branch-conflict-restart.bats.
  export RITE_REBASE_CONFLICT_RESTART_MAX=0
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
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

@test "rebase succeeds - branch behind, no conflicts" {
  # Test: Branch is 3 commits behind main, has 2 commits of its own, no conflicts
  # Expected: Rebase succeeds, branch is now up to date, force-push succeeds

  # Create feature branch with 2 commits
  local branch_name="fix/test-issue-42"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work 1" > feature1.txt
  git add feature1.txt
  git commit -m "Feature commit 1" >/dev/null 2>&1
  echo "feature work 2" > feature2.txt
  git add feature2.txt
  git commit -m "Feature commit 2" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main - add 3 commits with new files
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "main work $i" > "main-work-${i}.txt"
    git add "main-work-${i}.txt"
    git commit -m "Main commit $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree for the feature branch
  local worktree_path="$RITE_WORKTREE_DIR/issue-42"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Record commit count before rebase
  local commits_before
  commits_before=$(git -C "$worktree_path" rev-list --count HEAD 2>/dev/null)

  # Run rebase function
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  # Should succeed
  [ "$exit_code" -eq 0 ]

  # Verify branch now has main's new files
  [ -f "$worktree_path/main-work-1.txt" ]
  [ -f "$worktree_path/main-work-2.txt" ]
  [ -f "$worktree_path/main-work-3.txt" ]

  # Verify feature files still present
  [ -f "$worktree_path/feature1.txt" ]
  [ -f "$worktree_path/feature2.txt" ]

  # Verify branch is ahead of origin/main by exactly 2 commits (the feature commits)
  local commits_ahead
  commits_ahead=$(git -C "$worktree_path" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$commits_ahead" -eq 2 ]

  # Verify no merge commits (rebase doesn't create merge commits)
  local merge_commit_count
  merge_commit_count=$(git -C "$worktree_path" log origin/main..HEAD --merges --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$merge_commit_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "rebase conflicts - abort cleanly" {
  # Test: Branch modifies same file as main, rebase has conflicts
  # Expected: Rebase aborts cleanly, no leftover rebase state, function returns non-zero

  # Stub attempt_claude_merge_resolution to return 1 so this test deterministically
  # exercises the plain auto-bail path (print_error + return 1). Without the stub,
  # stale-branch.sh sources conflict-resolver.sh (present in lib/utils/), the resolver
  # is defined, and the auto-mode conflict path runs a real Claude session whose result
  # is non-deterministic (PR #103 wired this in after this test was written in PR #86).
  attempt_claude_merge_resolution() { return 1; }

  # Create feature branch that modifies README.md
  local branch_name="fix/conflicting-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "Feature line" >> README.md
  git add README.md
  git commit -m "Feature changes README" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Main also modifies README.md (conflict!)
  git checkout main >/dev/null 2>&1
  echo "Main line (conflict)" >> README.md
  git add README.md
  git commit -m "Main changes README" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-conflict"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Run rebase function (should fail). Use `run` so the expected non-zero return is
  # captured in $status rather than tripping bats' errexit on the bare command (the
  # auto-mode conflict bail returns 1 from stale-branch.sh — see the sibling test in
  # stale-branch-dirty-worktree.bats which uses the same pattern).
  run _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"

  # Should return non-zero (failure)
  [ "$status" -ne 0 ]

  # Verify no leftover rebase state
  [ ! -d "$worktree_path/.git/rebase-merge" ]
  [ ! -d "$worktree_path/.git/rebase-apply" ]

  # Verify branch is still on the original commit (rebase aborted)
  local current_message
  current_message=$(git -C "$worktree_path" log -1 --format=%s HEAD 2>/dev/null)
  [ "$current_message" = "Feature changes README" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "rebase uses force-with-lease push" {
  # Test: After successful rebase, push uses --force-with-lease (not regular push)
  # Expected: History is rewritten, regular push would fail, force-with-lease succeeds

  # Create feature branch
  local branch_name="fix/force-lease-test"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main
  git checkout main >/dev/null 2>&1
  echo "main work" > main.txt
  git add main.txt
  git commit -m "Main work" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-force-lease"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Record original commit SHA (before rebase)
  local original_sha
  original_sha=$(git -C "$worktree_path" rev-parse HEAD)

  # Run rebase
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Verify commit SHA changed (history was rewritten)
  local new_sha
  new_sha=$(git -C "$worktree_path" rev-parse HEAD)
  [ "$original_sha" != "$new_sha" ]

  # Verify remote branch was updated (force-push succeeded)
  local remote_sha
  remote_sha=$(git -C "$worktree_path" rev-parse origin/"$branch_name")
  [ "$new_sha" = "$remote_sha" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "rebase vs merge - no false conflicts with new files" {
  # Test: Reproduce the dogfooding scenario - main adds files branch doesn't have
  # Expected: Rebase handles cleanly (no conflicts), merge would report conflicts

  # Create feature branch (based on old main with only README.md)
  local branch_name="fix/dogfood-repro"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "fix for issue" > fix.txt
  git add fix.txt
  git commit -m "Fix implementation" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Main adds several new files (like bats tests in the real scenario)
  git checkout main >/dev/null 2>&1
  for i in 1 2 3 4; do
    echo "new test $i" > "test-${i}.bats"
    git add "test-${i}.bats"
    git commit -m "Add test file $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-dogfood"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Verify new files don't exist in branch yet
  [ ! -f "$worktree_path/test-1.bats" ]

  # Run rebase (should succeed without conflicts)
  _stale_rebase_onto_main "$worktree_path" "$branch_name" "auto"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # Verify new files now present
  [ -f "$worktree_path/test-1.bats" ]
  [ -f "$worktree_path/test-2.bats" ]
  [ -f "$worktree_path/test-3.bats" ]
  [ -f "$worktree_path/test-4.bats" ]

  # Verify fix commit is still present
  [ -f "$worktree_path/fix.txt" ]

  # Verify branch is 1 commit ahead of main (the fix commit, rebased)
  local commits_ahead
  commits_ahead=$(git -C "$worktree_path" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$commits_ahead" -eq 1 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_stale_branch auto: branch 2x threshold behind, no conflict - rebases not restarts" {
  # Acceptance criterion (issue #1137): auto mode attempts rebase first regardless of
  # distance. A clean branch at 2× threshold must rebase and continue (exit 0),
  # NOT close-and-restart. Reproduces the #1045 incident: PR #1089 was at exactly
  # the threshold, auto-closed, and the full feature was re-implemented from scratch.

  local branch_name="fix/two-x-threshold-$$"
  local issue_number="1045"
  local pr_number="1089"

  export RITE_STALE_BRANCH_THRESHOLD=10  # threshold = 10; we'll put branch 20 behind

  # Create feature branch with 1 work commit (no file conflicts with main)
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > feature-1045.txt
  git add feature-1045.txt
  git commit -m "Implement feature #1045" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main 20 commits ahead (2× threshold) with non-conflicting files
  git checkout main >/dev/null 2>&1
  local i
  for i in $(seq 1 20); do
    echo "main work $i" > "main-advance-${i}.txt"
    git add "main-advance-${i}.txt"
    git commit -m "Main advance $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-1045"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Run check_stale_branch in auto mode — should rebase (exit 0), NOT restart (exit 11)
  local exit_code=0
  check_stale_branch "$worktree_path" "$pr_number" "$issue_number" "auto" 2>/dev/null || exit_code=$?

  # Must NOT close-and-restart (exit 11 would mean PR destroyed and worktree removed)
  [ "$exit_code" -ne 11 ]

  # Must succeed (exit 0)
  [ "$exit_code" -eq 0 ]

  # Verify rebase happened — main's new files present in worktree
  [ -f "$worktree_path/main-advance-1.txt" ]
  [ -f "$worktree_path/main-advance-20.txt" ]

  # Verify feature work is preserved
  [ -f "$worktree_path/feature-1045.txt" ]

  # Verify no merge commits (rebase rewrites, no merge commit)
  local merge_count
  merge_count=$(git -C "$worktree_path" log origin/main..HEAD --merges --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$merge_count" -eq 0 ]

  # Worktree is still present (PR was NOT destroyed)
  [ -d "$worktree_path" ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}

@test "check_stale_branch auto: above threshold with conflict, resolver fails - exits 11 (close+restart)" {
  # Acceptance criterion (issue #1137): when rebase conflicts and the resolver fails,
  # auto mode falls back to close-and-restart (exit 11). This was the existing fallback
  # for below-threshold branches; it is now the universal fallback for all distances.

  local branch_name="fix/conflict-above-threshold-$$"
  local issue_number="1137"
  local pr_number="9999"

  export RITE_STALE_BRANCH_THRESHOLD=5     # threshold = 5; branch will be 8 behind
  export RITE_REBASE_CONFLICT_RESTART_MAX=0  # disable small-branch fast-path

  # Feature branch: modifies README.md (will conflict)
  git checkout -b "$branch_name" main >/dev/null 2>&1
  local i
  for i in 1 2 3 4 5; do
    echo "feature work $i" > "feature-conflict-${i}.txt"
    git add "feature-conflict-${i}.txt"
    git commit -m "Feature commit $i" >/dev/null 2>&1
  done
  # Final commit: modify README.md to produce conflict
  echo "Feature README change" >> README.md
  git add README.md
  git commit -m "Feature modifies README" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Advance main 8 commits (> threshold 5), last one also modifies README.md
  git checkout main >/dev/null 2>&1
  for i in $(seq 1 7); do
    echo "main advance $i" > "main-conflict-${i}.txt"
    git add "main-conflict-${i}.txt"
    git commit -m "Main advance $i" >/dev/null 2>&1
  done
  echo "Main README change (conflict)" >> README.md
  git add README.md
  git commit -m "Main modifies README" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-1137"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Stub the resolver to fail — ensures the conflict-fallback path fires, not LLM resolution
  # Re-stub after source per test runbook rule 2 (env-guarded libs overwrite pre-source stubs)
  attempt_claude_merge_resolution() { return 1; }

  # Stub gh_safe so close-and-cleanup doesn't hit GitHub
  gh_safe() { return 0; }

  # Run check_stale_branch in auto mode — should attempt rebase, fail on conflict,
  # fall back to close+restart → exit 11
  local exit_code=0
  check_stale_branch "$worktree_path" "$pr_number" "$issue_number" "auto" 2>/dev/null || exit_code=$?

  # Must exit 11 (close-and-restart fallback)
  [ "$exit_code" -eq 11 ]

  # Worktree should be gone (close-and-cleanup removed it)
  [ ! -d "$worktree_path" ]
}

@test "check_stale_branch uses rebase for below-threshold branches" {
  # Integration test: check_stale_branch function uses rebase (not merge)
  # Test: Branch is 3 commits behind (below default threshold of 10)
  # Expected: Function calls _stale_rebase_onto_main and succeeds

  # Create feature branch
  local branch_name="fix/integration-test-55"
  local issue_number="55"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Work on issue #55" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  # Diverge main by 3 commits (below threshold)
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "diverge $i" > "diverge-${i}.txt"
    git add "diverge-${i}.txt"
    git commit -m "Main divergence $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  # Create worktree
  local worktree_path="$RITE_WORKTREE_DIR/issue-55"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Create mock PR (issue not used in this test but required by function signature)
  local pr_number="99"

  # Run check_stale_branch with auto mode
  check_stale_branch "$worktree_path" "$pr_number" "$issue_number" "auto"
  local exit_code=$?

  # Should succeed (exit 0 = continue workflow)
  [ "$exit_code" -eq 0 ]

  # Verify rebase happened - main's new files should be present
  [ -f "$worktree_path/diverge-1.txt" ]
  [ -f "$worktree_path/diverge-2.txt" ]
  [ -f "$worktree_path/diverge-3.txt" ]

  # Verify no merge commits
  local merge_count
  merge_count=$(git -C "$worktree_path" log origin/main..HEAD --merges --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$merge_count" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$branch_name" >/dev/null 2>&1 || true
}
