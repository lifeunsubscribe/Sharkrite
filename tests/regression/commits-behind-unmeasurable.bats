#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh::get_commits_behind_main, lib/utils/branch-preflight.sh::classify_branch_health
# tests/regression/commits-behind-unmeasurable.bats
#
# Verifies that an unmeasurable behind-count is distinguishable from zero.
# Covers fix for issue #1469.
#
# Before this fix, get_commits_behind_main initialized COMMITS_BEHIND_MAIN=0
# and returned 0 in all cases — callers could not tell "genuinely current"
# from "could not measure". The fix: return 1 and leave COMMITS_BEHIND_MAIN=""
# when the count cannot be computed.

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

  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ── get_commits_behind_main unit tests ──────────────────────────────────────

@test "get_commits_behind_main: returns 1 and empty COMMITS_BEHIND_MAIN when origin ref does not exist" {
  local branch_name="fix/issue-42"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "work" > work.txt
  git add work.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-42"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  set +e
  get_commits_behind_main "$worktree_path" "nonexistent-base-branch"
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ -z "$COMMITS_BEHIND_MAIN" ]
}

@test "get_commits_behind_main: returns 1 and empty COMMITS_BEHIND_MAIN for orphan branch (no common ancestor)" {
  local branch_name="fix/issue-43"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "work" > work.txt
  git add work.txt
  git commit -m "Feature work" >/dev/null 2>&1

  git push origin "$branch_name" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-43"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Create an orphan branch inside the worktree (no shared ancestor with main)
  git -C "$worktree_path" checkout --orphan orphan-head >/dev/null 2>&1
  git -C "$worktree_path" rm -rf . >/dev/null 2>&1 || true
  echo "orphan" > "$worktree_path/orphan.txt"
  git -C "$worktree_path" add orphan.txt >/dev/null 2>&1
  git -C "$worktree_path" commit -m "Orphan commit" >/dev/null 2>&1

  set +e
  get_commits_behind_main "$worktree_path" "main"
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ -z "$COMMITS_BEHIND_MAIN" ]
}

@test "get_commits_behind_main: returns 0 and COMMITS_BEHIND_MAIN=0 for genuinely current branch" {
  local branch_name="fix/issue-44"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "work" > work.txt
  git add work.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push origin "$branch_name" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-44"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Branch was created from main tip — it is 0 commits behind main.
  git fetch origin main >/dev/null 2>&1

  set +e
  get_commits_behind_main "$worktree_path" "main"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$COMMITS_BEHIND_MAIN" = "0" ]
}

@test "get_commits_behind_main: returns 0 and correct count for branch behind by N commits" {
  local branch_name="fix/issue-45"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "work" > work.txt
  git add work.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push origin "$branch_name" >/dev/null 2>&1

  # Advance main on the remote by 3 commits (branch is now 3 behind)
  git checkout main >/dev/null 2>&1
  for i in 1 2 3; do
    echo "main advance $i" > "main-${i}.txt"
    git add "main-${i}.txt"
    git commit -m "Main advance $i" >/dev/null 2>&1
  done
  git push origin main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-45"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  git fetch origin main >/dev/null 2>&1

  set +e
  get_commits_behind_main "$worktree_path" "main"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$COMMITS_BEHIND_MAIN" = "3" ]
}

# ── check_stale_branch caller test ──────────────────────────────────────────

@test "check_stale_branch: continues gracefully when behind-count is unmeasurable" {
  # Create a feature branch and its worktree
  local branch_name="fix/issue-50"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "work" > work.txt
  git add work.txt
  git commit -m "Feature work" >/dev/null 2>&1
  git push origin "$branch_name" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-50"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Override get_commits_behind_main to simulate unmeasurable after the fetch.
  # Re-defined after source so the env-var guard does not overwrite it.
  get_commits_behind_main() {
    COMMITS_BEHIND_MAIN=""
    return 1
  }

  set +e
  check_stale_branch "$worktree_path" "" "50" "unsupervised"
  local rc=$?
  set -e

  # Must not crash; should return 0 (skip the stale check with a warning)
  [ "$rc" -eq 0 ]
}

# ── branch-preflight caller test ────────────────────────────────────────────

@test "classify_branch_health: returns STALE (2) when behind-count is unmeasurable" {
  source "$RITE_LIB_DIR/utils/branch-preflight.sh"
  set +u; set +o pipefail

  local branch_name="fix/issue-51"
  git checkout -b "$branch_name" main >/dev/null 2>&1
  git commit --allow-empty -m "chore: initialize work on #51" >/dev/null 2>&1
  echo "work" > work.txt
  git add work.txt
  git commit -m "Real work" >/dev/null 2>&1
  git push origin "$branch_name" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local worktree_path="$RITE_WORKTREE_DIR/issue-51"
  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Override get_commits_behind_main to simulate unmeasurable.
  # Re-defined after source so the env-var guard does not overwrite it.
  get_commits_behind_main() {
    COMMITS_BEHIND_MAIN=""
    return 1
  }

  set +e
  classify_branch_health "51" "$branch_name" "$worktree_path" "main"
  local rc=$?
  set -e

  # Unmeasurable should be treated as STALE (2) so the stale-branch handler
  # can perform a definitive check with its own hard fetch.
  [ "$rc" -eq 2 ]
}
