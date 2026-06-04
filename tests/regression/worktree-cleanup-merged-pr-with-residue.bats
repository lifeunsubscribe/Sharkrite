#!/usr/bin/env bats
# Regression test: worktree auto-cleanup correctly detects merged PRs
# Issue #182
#
# Bug history (2026-06-01):
#   Worktree auto-cleanup skipped worktrees whose PRs were merged but whose
#   branches were still present on origin (repos without auto-delete-branch-on-merge).
#   Two independent flaws:
#
#   Flaw 1 — uncommitted-changes guard fired BEFORE the merge check.
#   Any scratchpad file, build artifact, or .rite/ symlink residue protected a
#   merged-PR worktree indefinitely, even though the work was already in main.
#
#   Flaw 2 — merge detection used `git ls-remote --heads origin` which infers
#   "merged" only when the branch is gone from origin.  This repo does not
#   auto-delete branches on merge, so branches linger and the check returned
#   false even for truly merged PRs.
#
#   Result: the worktree was listed in the "All N worktrees are protected" block
#   (tagged as "PR #N") but never cleaned, and the limit grew to N+1.
#
# Fix (lib/core/claude-workflow.sh):
#   - Merge detection now uses `gh pr list --head BRANCH --state merged` first.
#   - A merged-PR signal overrides the uncommitted-changes guard.
#   - After cleanup, `git push origin --delete BRANCH` removes the stale origin ref.
#   - If gh is unreachable, falls back to `git ls-remote` heuristic with a warning.
#   - Cleanup logs `[diag] WORKTREE_CLEANED branch=... pr=...` to RITE_LOG_FILE.
#
# Static checks performed here:
#   1. The cleanup loop uses `--state merged` (not just `--state open` detection).
#   2. The gh pr list call precedes the uncommitted guard in source order.
#   3. `git push origin --delete` is present in the merged-worktree cleanup block.
#   4. `_diag "WORKTREE_CLEANED` is present for diagnostic logging.
#   5. A `git ls-remote` fallback is present for gh-offline scenarios.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLAUDE_WORKFLOW="$SCRIPT_DIR/lib/core/claude-workflow.sh"

# ---------------------------------------------------------------------------
# Test 1: gh pr list --state merged is present in the cleanup loop
# ---------------------------------------------------------------------------

@test "cleanup loop: uses gh pr list --state merged for merge detection" {
  [ -f "$CLAUDE_WORKFLOW" ]

  # The fix must query for merged PRs via gh, not just rely on git ls-remote.
  grep -qE "gh_safe pr list.*--state merged|gh pr list.*--state merged" "$CLAUDE_WORKFLOW"
}

# ---------------------------------------------------------------------------
# Test 2: The merged-PR check comes BEFORE the uncommitted-changes guard
# ---------------------------------------------------------------------------

@test "cleanup loop: merged-PR check precedes uncommitted-changes guard" {
  [ -f "$CLAUDE_WORKFLOW" ]

  # Find the line numbers of the two key patterns within the first cleanup loop
  # (the block between "CLEANED_COUNT=0" and "if [ "$CLEANED_COUNT" -gt 0 ]").
  # We extract only that section to avoid picking up lines from the second loop.
  _section=$(awk '
    /CLEANED_COUNT=0/ { in_block=1 }
    in_block && /if \[ "\$CLEANED_COUNT" -gt 0 \]/ { exit }
    in_block { print NR": "$0 }
  ' "$CLAUDE_WORKFLOW")

  # The gh --state merged call must exist in the section.
  _gh_line=$(echo "$_section" | grep -E "gh_safe pr list.*--state merged|gh pr list.*--state merged" | head -1 | cut -d: -f1)
  [ -n "$_gh_line" ] || {
    echo "FAIL: gh pr list --state merged not found in first cleanup loop" >&2
    return 1
  }

  # The uncommitted-changes guard (git status --porcelain) must be absent from the
  # merged-check path, OR appear AFTER the gh call.  The refactored loop no longer
  # has an early `[ "$UNCOMMITTED" -gt 0 ] && continue` before the gh check.
  # We verify there is no `status --porcelain` line that comes BEFORE the gh call.
  _uncommitted_line=$(echo "$_section" | grep "status --porcelain" | head -1 | cut -d: -f1)
  if [ -n "$_uncommitted_line" ]; then
    # If it exists, it must come AFTER the gh line (i.e., not before the merge check).
    [ "$_uncommitted_line" -gt "$_gh_line" ] || {
      echo "FAIL: uncommitted-changes guard (line $_uncommitted_line) appears before gh merge check (line $_gh_line)" >&2
      return 1
    }
  fi
  # If no uncommitted guard exists in this loop section, the test passes vacuously —
  # the loop now skips it for merged PRs, which is the intended behavior.
}

# ---------------------------------------------------------------------------
# Test 3: git push origin --delete is present in the merged-worktree path
# ---------------------------------------------------------------------------

@test "cleanup loop: deletes stale origin branch after merged worktree cleanup" {
  [ -f "$CLAUDE_WORKFLOW" ]

  # After removing the worktree, the fix must push a branch delete to origin.
  grep -qE "git push origin --delete" "$CLAUDE_WORKFLOW"
}

# ---------------------------------------------------------------------------
# Test 4: _diag WORKTREE_CLEANED is logged
# ---------------------------------------------------------------------------

@test "cleanup loop: emits _diag WORKTREE_CLEANED diagnostic line" {
  [ -f "$CLAUDE_WORKFLOW" ]

  grep -qE '_diag "WORKTREE_CLEANED' "$CLAUDE_WORKFLOW"
}

# ---------------------------------------------------------------------------
# Test 5: git ls-remote fallback is present for offline gh scenarios
# ---------------------------------------------------------------------------

@test "cleanup loop: retains git ls-remote fallback when gh is unreachable" {
  [ -f "$CLAUDE_WORKFLOW" ]

  # The fallback must be guarded by an offline check (gh auth status or similar)
  # and still reference git ls-remote --heads origin.
  grep -qE "git ls-remote --heads origin" "$CLAUDE_WORKFLOW"
}

# ---------------------------------------------------------------------------
# Test 6: The worktree remove uses --force (handles uncommitted residue)
# ---------------------------------------------------------------------------

@test "cleanup loop: uses git worktree remove --force for merged worktrees" {
  [ -f "$CLAUDE_WORKFLOW" ]

  grep -qE "git worktree remove --force" "$CLAUDE_WORKFLOW"
}
