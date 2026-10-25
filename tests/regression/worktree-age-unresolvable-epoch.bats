#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/repo-status.sh::compute_worktree_age
# tests/regression/worktree-age-unresolvable-epoch.bats
#
# Regression test for: `rite --status` rendered a bogus age for a worktree whose
# git linkage was gone.
#
# Bug: scan_worktrees computed the age with
#   last_commit_epoch=$(git -C "$path" log -1 --format='%ct' 2>/dev/null || echo "0")
# When the worktree's .git link file had been reaped out from under it (a /tmp
# scratchpad checkout eaten by macOS — the directory survives as empty husks, so
# the `[ -d ]` guard still admits it), `git log` fails, the epoch defaults to 0,
# and the age arithmetic measures against the Unix epoch. Live symptom
# (2026-10-25): a prunable worktree listed as
#   unknown                 clean             20751d old (stale)
# which also inflated STALE_WORKTREE_COUNT and so the "(N stale)" summary.
#
# Fix: compute_worktree_age reports "unknown age" / "unknown age (prunable)"
# when the epoch is empty, zero, or non-numeric, and does not touch
# STALE_WORKTREE_COUNT on that path.
#
# Tests:
# 1. A reaped worktree (dir present, no .git) reports "unknown age (prunable)"
# 2. A nonexistent path reports "unknown age (prunable)"
# 3. The unresolvable path does NOT increment STALE_WORKTREE_COUNT
# 4. A real git checkout still reports a numeric age
# 5. A genuinely old checkout is still marked "(stale)" and still counted

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="${RITE_REPO_ROOT}"
  source "${RITE_REPO_ROOT}/lib/utils/repo-status.sh" >/dev/null 2>&1
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  STALE_WORKTREE_COUNT=0
  WT_AGE_DISPLAY=""
}

@test "reaped worktree (dir present, .git gone) reports unknown age, not an epoch-derived one" {
  local husk="${RITE_TEST_TMPDIR}/reaped-worktree"
  mkdir -p "$husk/bin" "$husk/lib"   # empty husks, no .git — the live shape

  compute_worktree_age "$husk"

  [ "$WT_AGE_DISPLAY" = "unknown age (prunable)" ]
  # The specific bogus value the bug produced must never reappear
  [[ "$WT_AGE_DISPLAY" != *"20751d"* ]]
  [[ "$WT_AGE_DISPLAY" != *"d old"* ]]
}

@test "nonexistent worktree path reports unknown age" {
  compute_worktree_age "${RITE_TEST_TMPDIR}/does-not-exist"

  [ "$WT_AGE_DISPLAY" = "unknown age (prunable)" ]
}

@test "unresolvable age does not increment STALE_WORKTREE_COUNT" {
  local husk="${RITE_TEST_TMPDIR}/reaped-worktree-2"
  mkdir -p "$husk"

  STALE_WORKTREE_COUNT=0
  compute_worktree_age "$husk"

  [ "$STALE_WORKTREE_COUNT" -eq 0 ]
}

@test "real git checkout still reports a numeric age" {
  local repo="${RITE_TEST_TMPDIR}/real-repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "hello" > "$repo/f.txt"
  git -C "$repo" add f.txt
  git -C "$repo" commit -qm "initial"

  compute_worktree_age "$repo"

  # A just-made commit is under an hour old
  [ "$WT_AGE_DISPLAY" = "<1h old" ]
  [ "$STALE_WORKTREE_COUNT" -eq 0 ]
}

@test "genuinely old checkout is still marked stale and still counted" {
  local repo="${RITE_TEST_TMPDIR}/old-repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "hello" > "$repo/f.txt"
  git -C "$repo" add f.txt
  # 30 days ago — past the 168h stale threshold
  GIT_AUTHOR_DATE="$(( $(date +%s) - 2592000 ))" \
  GIT_COMMITTER_DATE="$(( $(date +%s) - 2592000 ))" \
    git -C "$repo" commit -qm "old commit"

  STALE_WORKTREE_COUNT=0
  compute_worktree_age "$repo"

  [[ "$WT_AGE_DISPLAY" == *"d old (stale)" ]]
  [ "$STALE_WORKTREE_COUNT" -eq 1 ]
}
