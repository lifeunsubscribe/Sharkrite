#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh, lib/utils/cleanup-worktrees.sh, lib/utils/git-helpers.sh
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

# ---------------------------------------------------------------------------
# Empty container dir cleanup after worktree removal (#972)
# merge-pr.sh deep-clean loop + current-worktree removal path
# cleanup-worktrees.sh manual cleanup path
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
MERGE_PR="$SCRIPT_DIR/lib/core/merge-pr.sh"
CLEANUP_WT="$SCRIPT_DIR/lib/utils/cleanup-worktrees.sh"

@test "empty container cleanup: behavioral fixture - empty parent is removed" {
  # Exercises the real rmdir_empty_worktree_container function from git-helpers.sh.
  #
  # Directory layout mirrors production:
  #   RITE_WORKTREE_DIR = .../sh-wt
  #   container         = .../sh-wt/issue-972  (child of RITE_WORKTREE_DIR)
  #   wt_path           = .../sh-wt/issue-972/fix
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-fixture"
  local rite_wt_dir="${test_dir}/sh-wt"
  local container="${rite_wt_dir}/issue-972"
  local wt_path="${container}/fix"

  mkdir -p "$wt_path"
  rm -rf "$wt_path"    # simulate git worktree remove

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  rmdir_empty_worktree_container "$container" "$rite_wt_dir"
  [ ! -d "$container" ]  # empty container must be gone; sh-wt itself is untouched
}

@test "empty container cleanup: behavioral fixture - non-empty parent is untouched" {
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-fixture2"
  local rite_wt_dir="${test_dir}/sh-wt"
  local container="${rite_wt_dir}/issue-972"
  local wt_path="${container}/fix"
  local sibling="${container}/issue-100-sibling"

  mkdir -p "$wt_path" "$sibling"
  rm -rf "$wt_path"    # simulate git worktree remove

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  rmdir_empty_worktree_container "$container" "$rite_wt_dir"
  [ -d "$container" ]  # sibling still there — container must survive
}

@test "empty container cleanup: sibling dir outside RITE_WORKTREE_DIR is NOT removed" {
  # Regression guard for the prefix-glob bug (#972): a sibling dir like sh-wt-archive
  # must NOT be removed when RITE_WORKTREE_DIR is sh-wt (bare prefix would match).
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-sibling"
  local rite_wt_dir="${test_dir}/sh-wt"
  local sibling_dir="${test_dir}/sh-wt-archive"  # sibling of sh-wt, NOT a child

  mkdir -p "$sibling_dir"

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  rmdir_empty_worktree_container "$sibling_dir" "$rite_wt_dir"
  [ -d "$sibling_dir" ]  # sibling dir must be untouched
}

@test "merge-pr source: stale-worktree loop calls rmdir_empty_worktree_container after removal" {
  # Structural pin for the deep-clean loop in merge-pr.sh.
  local remove_line rmdir_line
  remove_line=$(grep -n 'git worktree remove.*wt_path.*--force.*git worktree remove.*wt_path' "$MERGE_PR" | head -1 | cut -d: -f1)
  rmdir_line=$(grep -n 'rmdir_empty_worktree_container' "$MERGE_PR" | head -1 | cut -d: -f1)
  [ -n "$remove_line" ] || { echo "FAIL: stale-worktree removal not found in merge-pr.sh"; return 1; }
  [ -n "$rmdir_line" ]  || { echo "FAIL: rmdir_empty_worktree_container not found in merge-pr.sh"; return 1; }
  [ "$rmdir_line" -gt "$remove_line" ] || {
    echo "FAIL: first rmdir_empty_worktree_container (line $rmdir_line) must come after stale worktree remove (line $remove_line)"
    return 1
  }
}

@test "merge-pr source: current-worktree removal path calls rmdir_empty_worktree_container" {
  # Structural pin for the per-merge worktree removal (CURRENT_DIR path).
  local current_dir_remove_line rmdir_line2
  current_dir_remove_line=$(grep -n 'git worktree remove.*CURRENT_DIR.*--force' "$MERGE_PR" | head -1 | cut -d: -f1)
  # There are two call sites; the second follows the CURRENT_DIR removal.
  rmdir_line2=$(grep -n 'rmdir_empty_worktree_container' "$MERGE_PR" | tail -1 | cut -d: -f1)
  [ -n "$current_dir_remove_line" ] || { echo "FAIL: CURRENT_DIR worktree remove not found"; return 1; }
  [ -n "$rmdir_line2" ]             || { echo "FAIL: second rmdir_empty_worktree_container not found in merge-pr.sh"; return 1; }
  [ "$rmdir_line2" -gt "$current_dir_remove_line" ] || {
    echo "FAIL: second rmdir_empty_worktree_container (line $rmdir_line2) must come after CURRENT_DIR remove (line $current_dir_remove_line)"
    return 1
  }
}

@test "cleanup-worktrees source: calls rmdir_empty_worktree_container after manual worktree removal" {
  # Structural pin for the manual cleanup script.
  local remove_line rmdir_line
  remove_line=$(grep -n 'git worktree remove.*wt_path.*--force' "$CLEANUP_WT" | head -1 | cut -d: -f1)
  rmdir_line=$(grep -n 'rmdir_empty_worktree_container' "$CLEANUP_WT" | head -1 | cut -d: -f1)
  [ -n "$remove_line" ] || { echo "FAIL: git worktree remove not found in cleanup-worktrees.sh"; return 1; }
  [ -n "$rmdir_line" ]  || { echo "FAIL: rmdir_empty_worktree_container not found in cleanup-worktrees.sh"; return 1; }
  [ "$rmdir_line" -gt "$remove_line" ] || {
    echo "FAIL: rmdir_empty_worktree_container (line $rmdir_line) must come after git worktree remove (line $remove_line)"
    return 1
  }
}
