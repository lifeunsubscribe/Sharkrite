#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/repo-status.sh::compute_worktree_age
# Regression test for: epoch-derived age for prunable worktrees
#
# Bug: git log failed on a reaped worktree (no .git link file) but
# `|| echo "0"` produced epoch=0, which arithmetic rendered as ~20751d old.
# The bogus entry also incremented STALE_WORKTREE_COUNT.
#
# Fix: compute_worktree_age uses `|| true` so a failed git log yields an empty
# last_commit_epoch, which the helper maps to "unknown age (prunable)" without
# touching STALE_WORKTREE_COUNT.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_PROJECT_ROOT="$RITE_REPO_ROOT"

  REPO_STATUS="$RITE_REPO_ROOT/lib/utils/repo-status.sh"
  source "$REPO_STATUS"
  set +u; set +o pipefail
}

# =============================================================================
# Prunable husk: directory present, no .git — must not produce epoch-derived age
# =============================================================================

@test "compute_worktree_age: husk directory (no .git) reports unknown age (prunable)" {
  local td
  td="$(mktemp -d "${BATS_TEST_TMPDIR}/husk.XXXXXX")"
  STALE_WORKTREE_COUNT=0

  compute_worktree_age "$td"

  [ "$WT_AGE_DISPLAY" = "unknown age (prunable)" ]
}

@test "compute_worktree_age: husk directory does not increment STALE_WORKTREE_COUNT" {
  local td
  td="$(mktemp -d "${BATS_TEST_TMPDIR}/husk.XXXXXX")"
  STALE_WORKTREE_COUNT=0

  compute_worktree_age "$td"

  [ "$STALE_WORKTREE_COUNT" -eq 0 ]
}

@test "compute_worktree_age: husk display is never an epoch-derived 'Nd old'" {
  # Before the fix, epoch=0 produced ~20000d old. Guard: any "d old" age with
  # digits > 1000 days would be epoch-derived garbage (no real commit is that old).
  local td
  td="$(mktemp -d "${BATS_TEST_TMPDIR}/husk.XXXXXX")"
  STALE_WORKTREE_COUNT=0

  compute_worktree_age "$td"

  # Must NOT contain a number followed by "d old"
  [[ "$WT_AGE_DISPLAY" != *"d old"* ]]
}

# =============================================================================
# Valid checkout: must produce a real age, not "unknown age (prunable)"
# =============================================================================

@test "compute_worktree_age: valid git repo reports a numeric age" {
  # Use the repo root as a stand-in for any valid worktree.
  STALE_WORKTREE_COUNT=0

  compute_worktree_age "$RITE_REPO_ROOT"

  # Must not be the unresolvable sentinel
  [ "$WT_AGE_DISPLAY" != "unknown age (prunable)" ]
  # Must match one of the known display formats
  [[ "$WT_AGE_DISPLAY" == *"old"* ]] || [[ "$WT_AGE_DISPLAY" == "<1h old" ]]
}

# =============================================================================
# Stale checkout: >7 days old must be counted and marked
# =============================================================================

@test "compute_worktree_age: 30-day-old checkout is marked stale and counted" {
  command -v git >/dev/null 2>&1 || skip "git not available"

  local wt
  wt="$(mktemp -d "${BATS_TEST_TMPDIR}/old-wt.XXXXXX")"
  git -C "$wt" init -q
  git -C "$wt" config user.email "test@example.com"
  git -C "$wt" config user.name "Test"
  echo "content" > "$wt/file.txt"
  git -C "$wt" add file.txt

  # Commit dated 31 days ago
  local old_ts
  old_ts=$(( $(date +%s) - 31 * 86400 ))
  GIT_COMMITTER_DATE="@${old_ts} +0000" GIT_AUTHOR_DATE="@${old_ts} +0000" \
    git -C "$wt" commit -q -m "old commit"

  STALE_WORKTREE_COUNT=0
  compute_worktree_age "$wt"

  # Must contain "(stale)"
  [[ "$WT_AGE_DISPLAY" == *"(stale)"* ]]
  # STALE_WORKTREE_COUNT must be incremented
  [ "$STALE_WORKTREE_COUNT" -eq 1 ]
  # Must show "d old" (days), roughly 31d — not epoch-derived thousands
  [[ "$WT_AGE_DISPLAY" == *"d old"* ]]
  local days
  days=$(echo "$WT_AGE_DISPLAY" | grep -oE '^[0-9]+' || true)
  [ -n "$days" ]
  [ "$days" -ge 30 ]
  [ "$days" -lt 40 ]
}

@test "compute_worktree_age: recent checkout (today) does not increment STALE_WORKTREE_COUNT" {
  command -v git >/dev/null 2>&1 || skip "git not available"

  local wt
  wt="$(mktemp -d "${BATS_TEST_TMPDIR}/recent-wt.XXXXXX")"
  git -C "$wt" init -q
  git -C "$wt" config user.email "test@example.com"
  git -C "$wt" config user.name "Test"
  echo "content" > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" commit -q -m "recent commit"

  STALE_WORKTREE_COUNT=0
  compute_worktree_age "$wt"

  [ "$STALE_WORKTREE_COUNT" -eq 0 ]
  [ "$WT_AGE_DISPLAY" != "unknown age (prunable)" ]
}
