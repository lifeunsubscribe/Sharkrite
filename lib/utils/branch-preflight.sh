#!/bin/bash
# lib/utils/branch-preflight.sh
# Preflight branch sanity check before entering existing worktree.
# Classifies branch state and decides whether to proceed, recover, or fail.
#
# Exit codes from classify_branch_health:
#   0  = HEALTHY (proceed to dev work)
#   1  = ERROR (worktree missing or internal failure)
#   2  = STALE (has real work but behind base branch — route to stale-branch handler)
#   3  = EMPTY_INIT (only init commit, clean tree — auto-recover by restart)
#   4  = DIVERGENT_NO_WORK (behind base branch + only init commit — auto-recover)
#   5  = UNCOMMITTED_PRESERVED (uncommitted changes — route to auto-commit handler)

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f classify_branch_health >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

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

# classify_branch_health ISSUE_NUMBER BRANCH_NAME WORKTREE_PATH [BASE_BRANCH]
#
# Classifies branch state. Does NOT modify state — caller decides action.
# BASE_BRANCH defaults to "main" when omitted (backward compatible).
# Exit codes: 0 (HEALTHY), 2 (STALE), 3 (EMPTY_INIT), 4 (DIVERGENT_NO_WORK), 5 (UNCOMMITTED_PRESERVED)
classify_branch_health() {
  local issue_number="$1"
  local branch_name="$2"
  local worktree_path="$3"
  local base_branch="${4:-main}"

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

  # Fetch the resolved base branch to ensure accurate behind-count
  git -C "$worktree_path" fetch origin "$base_branch" 2>/dev/null || true

  # Check if branch has only init commit
  local has_only_init
  _preflight_has_only_init_commit "$worktree_path" "$issue_number" "$base_branch"
  has_only_init=$?

  # Check if branch is behind base (uses get_commits_behind_main from stale-branch.sh)
  get_commits_behind_main "$worktree_path" "$base_branch"
  local behind="${COMMITS_BEHIND_MAIN:-0}"

  # Classification logic (decision tree):
  # 1. Only init commit + behind base → DIVERGENT_NO_WORK (4)
  # 2. Only init commit + up-to-date → EMPTY_INIT (3)
  # 3. Has real work + behind base → STALE (2)
  # 4. Has real work + up-to-date → HEALTHY (0)
  # (Uncommitted changes already returned 5 above)
  if [ "$has_only_init" -eq 0 ]; then
    # Only init commit exists
    if [ "$behind" -gt 0 ]; then
      # Behind base + only init = DIVERGENT_NO_WORK
      print_warning "Branch has only init commit and is $behind commit(s) behind $base_branch"
      return 4
    else
      # Up-to-date but only init commit = EMPTY_INIT
      print_warning "Branch has only init commit (no real work)"
      return 3
    fi
  fi

  # Has real work
  if [ "$behind" -gt 0 ]; then
    # Real work but behind base = STALE
    print_info "Branch has real work but is $behind commit(s) behind $base_branch"
    return 2
  fi

  # Default: HEALTHY (real work, up-to-date, clean tree)
  return 0
}

# ===================================================================
# INTERNAL: Detection helpers
# ===================================================================

# _preflight_has_only_init_commit WORKTREE_PATH ISSUE_NUMBER [BASE_BRANCH]
#
# Returns 0 if branch has ONLY a "chore: initialize work on #N" commit, 1 otherwise.
# BASE_BRANCH defaults to "main" when omitted (backward compatible).
_preflight_has_only_init_commit() {
  local worktree_path="$1"
  local issue_number="$2"
  local base_branch="${3:-main}"

  # Get all commits ahead of the base branch
  local commits_ahead
  commits_ahead=$(git -C "$worktree_path" log --oneline "origin/$base_branch..HEAD" 2>/dev/null || echo "")

  if [ -z "$commits_ahead" ]; then
    # No commits ahead of base branch — not even an init commit
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

  # Close PR if it exists and is a draft with no real work.
  # Race condition safety: track whether PR close succeeded before deleting
  # the remote branch. If PR close fails but branch is deleted, GitHub is left
  # in an inconsistent state (open PR pointing to a missing branch).
  local _preflight_pr_close_ok=false
  if [ -n "$pr_number" ]; then
    local pr_state
    pr_state=$(gh_safe pr view "$pr_number" --json isDraft,state --jq '.isDraft,.state' | paste -sd ',' - || true)
    pr_state="${pr_state:-}"

    # Validate pr_state before checking (protect against paste/gh failures)
    if [ -z "$pr_state" ] || ! echo "$pr_state" | grep -qE '^(true|false),(OPEN|CLOSED|MERGED)$'; then
      print_warning "Failed to detect PR state for issue #${issue_number:-?} — skipping PR cleanup"
    elif echo "$pr_state" | grep -qE "(CLOSED|MERGED)"; then
      # PR already closed/merged — safe to proceed with branch deletion
      _preflight_pr_close_ok=true
      print_info "Issue #${issue_number:-?}'s PR is already closed/merged"
    elif echo "$pr_state" | grep -q "true"; then
      # Draft PR — check if it has zero additions (empty)
      local additions
      additions=$(gh_safe pr view "$pr_number" --json additions --jq '.additions' || true)
      additions="${additions:-0}"
      # Normalize: gh can return empty or "null" on API errors; coerce to integer
      if ! [[ "$additions" =~ ^[0-9]+$ ]]; then
        additions=0
      fi

      if [ "$additions" -eq 0 ]; then
        print_status "Closing empty draft PR for issue #${issue_number:-?}..."
        local close_comment="Auto-closing: Branch has no real work (only init commit). Restarting fresh."
        echo "$close_comment" | gh_safe pr comment "$pr_number" --body-file - 2>/dev/null || true
        # gh_safe handles transient retries; capture exit code via || assignment
        local _close_out
        local _close_exit=0
        _close_out=$(gh_safe pr close "$pr_number" 2>&1) || _close_exit=$?
        if [ "${_close_exit:-1}" -eq 0 ]; then
          _preflight_pr_close_ok=true
          print_info "Closed PR for issue #${issue_number:-?}"
        elif echo "$_close_out" | grep -qiE "already closed|already merged|no open pull request|Pull request .* is already closed"; then
          # NOTE: "not found" is intentionally excluded — it can match genuine API errors
          # (e.g. wrong PR number, network issue) and would falsely permit branch deletion
          # while the PR is still OPEN, re-introducing the race condition this code guards against.
          _preflight_pr_close_ok=true
          print_info "Issue #${issue_number:-?}'s PR already resolved — continuing cleanup"
        else
          print_warning "Failed to close PR for issue #${issue_number:-?} — remote branch deletion skipped to avoid inconsistent state"
          print_warning "  gh output: $(echo "$_close_out" | head -1)"
        fi
      else
        # Non-empty open draft PR — do NOT delete the remote branch.
        # Deleting the branch while the PR is still open would leave GitHub in an
        # inconsistent state (open PR pointing at a missing branch) — exactly the
        # race condition this entire PR was created to prevent.
        _preflight_pr_close_ok=false
        print_warning "Issue #${issue_number:-?}'s PR is an open draft with real work — remote branch deletion skipped to avoid inconsistent state"
      fi
    fi
  else
    # No PR — branch deletion is unconditionally safe
    _preflight_pr_close_ok=true
  fi

  # Exit worktree before removing it
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || cd "$HOME"

  # Remove worktree (local filesystem — safe regardless of PR close result)
  if git worktree remove "$worktree_path" --force 2>/dev/null; then
    print_info "Removed worktree: $(basename "$worktree_path")"
  else
    print_warning "Failed to remove worktree: $worktree_path"
  fi

  # Delete local branch (local — safe regardless of PR close result)
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git branch -D "$branch_name" 2>/dev/null || true
    print_info "Deleted local branch: $branch_name"
  fi

  # Delete remote branch — only if PR close succeeded (or PR was already resolved).
  # This prevents the inconsistent state: open PR + deleted branch.
  if [ "$_preflight_pr_close_ok" = true ]; then
    git push origin --delete "$branch_name" 2>/dev/null || true
  fi

  # Remove session state file
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR:-.rite}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    print_info "Removed session state"
  fi

  print_success "Empty branch cleanup complete — ready to restart fresh"
  return 0
}
