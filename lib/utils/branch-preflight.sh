#!/bin/bash
# lib/utils/branch-preflight.sh
# Preflight branch sanity check before entering existing worktree.
# Classifies branch state and decides whether to proceed, recover, or fail.
#
# Exit codes from classify_branch_health:
#   0  = HEALTHY (proceed to dev work)
#   2  = STALE (has real work but behind main — route to stale-branch handler)
#   3  = EMPTY_INIT (only init commit, clean tree — auto-recover by restart)
#   4  = DIVERGENT_NO_WORK (behind main + only init commit — auto-recover)
#   5  = UNCOMMITTED_PRESERVED (uncommitted changes — route to auto-commit handler)

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

# Source stale-branch utilities for commits-behind detection
if ! source "$RITE_LIB_DIR/utils/stale-branch.sh" 2>/dev/null; then
  echo "ERROR: Failed to source stale-branch.sh" >&2
  exit 1
fi

# ===================================================================
# PUBLIC: Main entry point
# ===================================================================

# classify_branch_health ISSUE_NUMBER BRANCH_NAME WORKTREE_PATH
#
# Classifies branch state. Does NOT modify state — caller decides action.
# Exit codes: 0 (HEALTHY), 2 (STALE), 3 (EMPTY_INIT), 4 (DIVERGENT_NO_WORK), 5 (UNCOMMITTED_PRESERVED)
classify_branch_health() {
  local issue_number="$1"
  local branch_name="$2"
  local worktree_path="$3"

  # Sanity checks
  if [ ! -d "$worktree_path" ]; then
    print_error "Worktree does not exist: $worktree_path"
    return 1
  fi

  # Check for uncommitted changes first (highest priority)
  local uncommitted_count
  uncommitted_count=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$uncommitted_count" -gt 0 ]; then
    # Uncommitted changes detected — caller should handle (usually already handled before this)
    # Return 5 to signal this state, but don't act on it here
    return 5
  fi

  # Fetch origin/main to ensure accurate behind-count
  git -C "$worktree_path" fetch origin main 2>/dev/null || true

  # Check if branch has only init commit
  local has_only_init
  _preflight_has_only_init_commit "$worktree_path" "$issue_number"
  has_only_init=$?

  # Check if branch is behind main (uses get_commits_behind_main from stale-branch.sh)
  get_commits_behind_main "$worktree_path"
  local behind="$COMMITS_BEHIND_MAIN"

  # Classification logic (decision tree):
  # 1. Only init commit + behind main → DIVERGENT_NO_WORK (4)
  # 2. Only init commit + up-to-date → EMPTY_INIT (3)
  # 3. Has real work + behind main → STALE (2)
  # 4. Has real work + up-to-date → HEALTHY (0)
  # (Uncommitted changes already returned 5 above)
  if [ "$has_only_init" -eq 0 ]; then
    # Only init commit exists
    if [ "$behind" -gt 0 ]; then
      # Behind main + only init = DIVERGENT_NO_WORK
      print_warning "Branch has only init commit and is $behind commit(s) behind main"
      return 4
    else
      # Up-to-date but only init commit = EMPTY_INIT
      print_warning "Branch has only init commit (no real work)"
      return 3
    fi
  fi

  # Has real work
  if [ "$behind" -gt 0 ]; then
    # Real work but behind main = STALE
    print_info "Branch has real work but is $behind commit(s) behind main"
    return 2
  fi

  # Default: HEALTHY (real work, up-to-date, clean tree)
  return 0
}

# ===================================================================
# INTERNAL: Detection helpers
# ===================================================================

# _preflight_has_only_init_commit WORKTREE_PATH ISSUE_NUMBER
#
# Returns 0 if branch has ONLY a "chore: initialize work on #N" commit, 1 otherwise.
_preflight_has_only_init_commit() {
  local worktree_path="$1"
  local issue_number="$2"

  # Get all commits ahead of origin/main
  local commits_ahead
  commits_ahead=$(git -C "$worktree_path" log --oneline origin/main..HEAD 2>/dev/null || echo "")

  if [ -z "$commits_ahead" ]; then
    # No commits ahead of main — not even an init commit
    return 1
  fi

  # Count total commits ahead
  local commit_count
  commit_count=$(echo "$commits_ahead" | wc -l | tr -d ' ')

  if [ "$commit_count" -ne 1 ]; then
    # More than one commit — has real work
    return 1
  fi

  # Exactly one commit — check if it's the init commit
  if echo "$commits_ahead" | grep -qE "chore: initialize work on #${issue_number}"; then
    return 0
  fi

  # One commit but not the init pattern — has real work
  return 1
}

# ===================================================================
# PUBLIC: Auto-recovery for empty/divergent branches
# ===================================================================

# preflight_auto_recover_empty ISSUE_NUMBER BRANCH_NAME WORKTREE_PATH [PR_NUMBER]
#
# Blows away worktree + branch + draft PR (if exists), signals restart.
# Does NOT restart the workflow itself — caller must restart.
# Returns 0 on success, 1 on failure.
preflight_auto_recover_empty() {
  local issue_number="$1"
  local branch_name="$2"
  local worktree_path="$3"
  local pr_number="${4:-}"

  print_status "Auto-recovering from empty/divergent branch..."

  # Detect PR if not provided
  if [ -z "$pr_number" ]; then
    source "$RITE_LIB_DIR/utils/pr-detection.sh"
    if detect_pr_for_issue "$issue_number"; then
      pr_number="$PR_NUMBER"
    fi
  fi

  # Close PR if it exists and is a draft with no real work
  if [ -n "$pr_number" ]; then
    local pr_state
    pr_state=$(gh pr view "$pr_number" --json isDraft,state --jq '.isDraft,.state' 2>/dev/null | paste -sd ',' - || echo "")

    if echo "$pr_state" | grep -q "true"; then
      # Draft PR — check if it has zero additions (empty)
      local additions
      additions=$(gh pr view "$pr_number" --json additions --jq '.additions' 2>/dev/null || echo "0")

      if [ "$additions" -eq 0 ]; then
        print_status "Closing empty draft PR #$pr_number..."
        local close_comment="Auto-closing: Branch has no real work (only init commit). Restarting fresh."
        echo "$close_comment" | gh pr comment "$pr_number" --body-file - 2>/dev/null || true
        gh pr close "$pr_number" 2>/dev/null || print_warning "Failed to close PR #$pr_number"
      fi
    fi
  fi

  # Exit worktree before removing it
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || cd "$HOME"

  # Remove worktree
  if git worktree remove "$worktree_path" --force 2>/dev/null; then
    print_info "Removed worktree: $(basename "$worktree_path")"
  else
    print_warning "Failed to remove worktree: $worktree_path"
  fi

  # Delete local branch
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git branch -D "$branch_name" 2>/dev/null || true
    print_info "Deleted local branch: $branch_name"
  fi

  # Delete remote branch (best effort)
  git push origin --delete "$branch_name" 2>/dev/null || true

  # Remove session state file
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR:-.rite}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    print_info "Removed session state"
  fi

  print_success "Empty branch cleanup complete — ready to restart fresh"
  return 0
}
