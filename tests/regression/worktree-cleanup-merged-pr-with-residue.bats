#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh, lib/utils/cleanup-worktrees.sh, lib/utils/git-helpers.sh, lib/core/workflow-runner.sh, lib/utils/stale-branch.sh
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

@test "empty container cleanup: behavioral fixture - empty worktree dir is removed" {
  # Exercises the real rmdir_empty_worktree_container function from git-helpers.sh.
  #
  # Directory layout mirrors production (flat layout):
  #   RITE_WORKTREE_DIR = .../sh-wt
  #   wt_path           = .../sh-wt/fx-issue-972  (direct child of RITE_WORKTREE_DIR)
  #
  # After `git worktree remove`, git deletes the .git file but the directory
  # may remain empty.  rmdir_empty_worktree_container removes it.
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-fixture"
  local rite_wt_dir="${test_dir}/sh-wt"
  local wt_path="${rite_wt_dir}/fx-issue-972"

  mkdir -p "$wt_path"
  # Simulate git worktree remove leaving an empty directory (git deletes .git
  # file but leaves the dir when residue is absent — rmdir cleans that up).

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  rmdir_empty_worktree_container "$wt_path" "$rite_wt_dir"
  [ ! -d "$wt_path" ]   # empty worktree dir must be gone; sh-wt itself is untouched
}

@test "empty container cleanup: behavioral fixture - non-empty worktree dir is untouched" {
  # When the worktree dir still contains residue files after git worktree remove,
  # rmdir must fail silently and leave the directory in place.
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-fixture2"
  local rite_wt_dir="${test_dir}/sh-wt"
  local wt_path="${rite_wt_dir}/fx-issue-972"
  local residue="${wt_path}/sharkrite-scratchpad.md"

  mkdir -p "$wt_path"
  touch "$residue"   # residue file — rmdir must not remove it

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  rmdir_empty_worktree_container "$wt_path" "$rite_wt_dir"
  [ -d "$wt_path" ]    # non-empty worktree dir must survive
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

@test "empty container cleanup: trailing slash in RITE_WORKTREE_DIR is normalized" {
  # Regression guard for the trailing-slash bug: RITE_WORKTREE_DIR with a
  # trailing slash produces pattern ".../base//*" which fails to match a
  # direct child like ".../base/fx-foo", rendering the helper silently inert.
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-trailing-slash"
  local rite_wt_dir="${test_dir}/sh-wt"
  local wt_path="${rite_wt_dir}/fx-issue-972"

  mkdir -p "$wt_path"

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  # Pass rite_wt_dir WITH a trailing slash — the function must normalize it.
  rmdir_empty_worktree_container "$wt_path" "${rite_wt_dir}/"
  [ ! -d "$wt_path" ]   # must be removed despite trailing slash in second arg
}

@test "empty container cleanup: empty first arg is a no-op (does not rmdir /)" {
  # Safety anchor: when wt_path is empty the case pattern becomes "/*" and would
  # match ANY path.  The guard must return 0 before reaching the case statement.
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-empty-arg"
  local rite_wt_dir="${test_dir}/sh-wt"
  mkdir -p "$rite_wt_dir"

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  # Empty first arg: must return 0 without attempting any rmdir.
  rmdir_empty_worktree_container "" "$rite_wt_dir"
  [ -d "$rite_wt_dir" ]  # container dir must be untouched
}

@test "empty container cleanup: empty second arg is a no-op (does not match /*)" {
  # Safety anchor: when rite_worktree_dir is empty the pattern becomes "/*" which
  # would match any absolute path.  The guard must return 0 before the case.
  local test_dir="${BATS_TEST_TMPDIR}/rmdir-empty-base"
  local wt_path="${test_dir}/sh-wt/fx-issue-972"
  mkdir -p "$wt_path"

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: git-helpers.sh uses declare -f git_fetch_safe guard; rmdir_empty_worktree_container is not stubbed above
  source "${SCRIPT_DIR}/lib/utils/git-helpers.sh"
  set +u; set +o pipefail

  # Empty second arg: must return 0 without attempting any rmdir.
  rmdir_empty_worktree_container "$wt_path" ""
  [ -d "$wt_path" ]  # worktree dir must be untouched
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

# ---------------------------------------------------------------------------
# Sibling worktree-removal sites (#980)
# workflow-runner.sh handle_closed_issue + stale-branch.sh _stale_close_and_cleanup
# ---------------------------------------------------------------------------

WORKFLOW_RUNNER="$SCRIPT_DIR/lib/core/workflow-runner.sh"
STALE_BRANCH="$SCRIPT_DIR/lib/utils/stale-branch.sh"

@test "workflow-runner source: handle_closed_issue calls rmdir_empty_worktree_container after git worktree remove" {
  # Structural pin: the call must appear after the worktree remove in handle_closed_issue.
  # These are the closed-issue cleanup sites (sibling of the merge-pr.sh deep-clean loop).
  local remove_line rmdir_line
  remove_line=$(grep -n 'git worktree remove.*wt_path.*--force' "$WORKFLOW_RUNNER" | head -1 | cut -d: -f1)
  rmdir_line=$(grep -n 'rmdir_empty_worktree_container' "$WORKFLOW_RUNNER" | head -1 | cut -d: -f1)
  [ -n "$remove_line" ] || { echo "FAIL: git worktree remove not found in workflow-runner.sh"; return 1; }
  [ -n "$rmdir_line" ]  || { echo "FAIL: rmdir_empty_worktree_container not found in workflow-runner.sh"; return 1; }
  [ "$rmdir_line" -gt "$remove_line" ] || {
    echo "FAIL: rmdir_empty_worktree_container (line $rmdir_line) must come after git worktree remove (line $remove_line)"
    return 1
  }
}

@test "stale-branch source: _stale_close_and_cleanup calls rmdir_empty_worktree_container after git worktree remove" {
  # Structural pin: the call must appear after the worktree remove in _stale_close_and_cleanup.
  # This is the close-and-restart path (stale branch threshold exceeded).
  local remove_line rmdir_line
  remove_line=$(grep -n 'git worktree remove.*worktree_path.*--force' "$STALE_BRANCH" | head -1 | cut -d: -f1)
  rmdir_line=$(grep -n 'rmdir_empty_worktree_container' "$STALE_BRANCH" | head -1 | cut -d: -f1)
  [ -n "$remove_line" ] || { echo "FAIL: git worktree remove not found in stale-branch.sh"; return 1; }
  [ -n "$rmdir_line" ]  || { echo "FAIL: rmdir_empty_worktree_container not found in stale-branch.sh"; return 1; }
  [ "$rmdir_line" -gt "$remove_line" ] || {
    echo "FAIL: rmdir_empty_worktree_container (line $rmdir_line) must come after git worktree remove (line $remove_line)"
    return 1
  }
}

@test "workflow-runner source: sources git-helpers.sh (provides rmdir_empty_worktree_container)" {
  # Guard: the function must be available at runtime in workflow-runner.sh.
  grep -qE 'source.*git-helpers\.sh' "$WORKFLOW_RUNNER"
}

@test "stale-branch source: sources git-helpers.sh (provides rmdir_empty_worktree_container)" {
  # Guard: the function must be available at runtime in stale-branch.sh.
  grep -qE 'source.*git-helpers\.sh' "$STALE_BRANCH"
}
