#!/bin/bash
# lib/utils/stale-branch.sh
# Stale branch detection and handling.
# Checks how far a feature branch is behind origin/main and responds:
#   - Below threshold: merge origin/main into branch (like GitHub "Update branch")
#   - At/above threshold: close PR, cleanup, signal fresh restart
#
# Threshold controlled by RITE_STALE_BRANCH_THRESHOLD (default: 10 commits).

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

# ===================================================================
# PUBLIC: Detection
# ===================================================================

# get_commits_behind_main WORKTREE_PATH
#
# Sets: COMMITS_BEHIND_MAIN (integer)
# Does NOT fetch — caller must ensure origin/main is up to date.
get_commits_behind_main() {
  local worktree_path="$1"
  COMMITS_BEHIND_MAIN=0

  local merge_base
  merge_base=$(git -C "$worktree_path" merge-base HEAD origin/main 2>/dev/null || echo "")

  if [ -z "$merge_base" ]; then
    return 0
  fi

  COMMITS_BEHIND_MAIN=$(git -C "$worktree_path" rev-list --count "${merge_base}..origin/main" 2>/dev/null || echo "0")
  return 0
}

# ===================================================================
# PUBLIC: Main entry point
# ===================================================================

# check_stale_branch WORKTREE_PATH PR_NUMBER ISSUE_NUMBER WORKFLOW_MODE
#
# Exit codes:
#   0  = continue workflow (branch is current, or was merged with main)
#   1  = abort (user chose abort, or unrecoverable error)
#   10 = restarted fresh (PR closed, artifacts cleaned — caller must reset variables)
check_stale_branch() {
  local worktree_path="$1"
  local pr_number="$2"
  local issue_number="$3"
  local workflow_mode="$4"

  local branch_name
  branch_name=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [ -z "$branch_name" ] || [ "$branch_name" = "main" ] || [ "$branch_name" = "master" ]; then
    return 0  # Not on a feature branch
  fi

  # Fetch origin/main to ensure up-to-date count
  print_status "Checking branch freshness against main..."
  if ! git -C "$worktree_path" fetch origin main 2>/dev/null; then
    print_warning "Could not fetch origin/main — skipping stale branch check"
    return 0
  fi

  get_commits_behind_main "$worktree_path"
  local behind="$COMMITS_BEHIND_MAIN"

  if [ "$behind" -eq 0 ]; then
    print_info "Branch is up to date with main"
    return 0
  fi

  local threshold="${RITE_STALE_BRANCH_THRESHOLD:-10}"

  if [ "$behind" -lt "$threshold" ]; then
    # Below threshold: merge main into branch
    print_info "Branch is $behind commit(s) behind main (threshold: $threshold) — merging main"
    _stale_merge_main "$worktree_path" "$branch_name" "$workflow_mode"
    return $?
  fi

  # At or above threshold
  print_warning "Branch is $behind commit(s) behind main (threshold: $threshold)"

  if [ "$workflow_mode" = "supervised" ]; then
    _stale_supervised_prompt "$worktree_path" "$pr_number" "$issue_number" "$branch_name" "$behind"
    return $?
  else
    # Auto mode: close and restart
    print_status "Closing stale PR and restarting fresh..."
    _stale_close_and_cleanup "$pr_number" "$issue_number" "$worktree_path" "$branch_name" "$behind"
    return 10
  fi
}

# ===================================================================
# PUBLIC: Close comment formatting
# ===================================================================

# format_stale_close_comment WORKTREE_PATH COMMITS_BEHIND
# Outputs the PR close comment body to stdout.
format_stale_close_comment() {
  local worktree_path="$1"
  local behind="$2"

  local commit_messages
  commit_messages=$(git -C "$worktree_path" log --oneline origin/main..HEAD 2>/dev/null || echo "(none)")

  local changed_files
  changed_files=$(git -C "$worktree_path" diff --name-only origin/main..HEAD 2>/dev/null || echo "(none)")

  cat <<EOF
:arrows_counterclockwise: Closing: Branch is ${behind} commits behind main.

**Work summary:**
\`\`\`
${commit_messages}
\`\`\`

**Files modified:**
\`\`\`
${changed_files}
\`\`\`

This branch has diverged too far from main for safe integration.
A fresh implementation will be started from current main.
EOF
}

# ===================================================================
# INTERNAL: Merge main into branch
# ===================================================================

# _stale_merge_main WORKTREE_PATH BRANCH_NAME WORKFLOW_MODE
#
# Merges origin/main into the feature branch. Same as GitHub "Update branch".
# No force-push needed — history isn't rewritten, regular git push works.
_stale_merge_main() {
  local worktree_path="$1"
  local branch_name="$2"
  local workflow_mode="$3"

  cd "$worktree_path" || return 1

  # Stash dirty worktree if needed
  local _stashed=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    print_status "Stashing uncommitted changes before merge..."
    git stash push -m "stale-branch: auto-stash before merge main" 2>/dev/null || true
    _stashed=true
  fi

  local merge_output
  if merge_output=$(git merge origin/main --no-edit 2>&1); then
    # Merge succeeded — restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || {
        print_warning "Stash pop had conflicts — stash preserved (run 'git stash pop' manually)"
      }
    fi

    # Push the merge commit
    if git push origin "$branch_name" 2>/dev/null; then
      print_success "Merged main into branch and pushed"
      return 0
    else
      print_error "Push failed after merge"
      return 1
    fi
  else
    # Merge had conflicts — abort it
    print_warning "Merge with main had conflicts"
    git merge --abort 2>/dev/null || true

    # Restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || true
    fi

    if [ "$workflow_mode" = "supervised" ]; then
      echo "" >&2
      echo "Conflicting with main. Options:" >&2
      echo "  c) Continue without merging main (not recommended)" >&2
      echo "  d) Abort workflow" >&2
      read -p "Choose [c/d]: " -n 1 -r >&2
      echo >&2
      case "$REPLY" in
        c|C) return 0 ;;
        *)   return 1 ;;
      esac
    else
      print_error "Merge with main failed (conflicts) — cannot proceed in auto mode"
      print_info "Run 'rite $issue_number --supervised' to resolve manually"
      return 1
    fi
  fi
}

# ===================================================================
# INTERNAL: Close PR and cleanup
# ===================================================================

# _stale_close_and_cleanup PR_NUMBER ISSUE_NUMBER WORKTREE_PATH BRANCH_NAME COMMITS_BEHIND
#
# Inline cleanup (does NOT call undo-workflow.sh).
# Best-effort: individual failures warn but don't stop.
_stale_close_and_cleanup() {
  local pr_number="$1"
  local issue_number="$2"
  local worktree_path="$3"
  local branch_name="$4"
  local behind="$5"

  # 1. Generate and post close comment
  local comment_body
  comment_body=$(format_stale_close_comment "$worktree_path" "$behind")

  if ! gh pr comment "$pr_number" --body "$comment_body" 2>/dev/null; then
    print_warning "Failed to post close comment on PR #$pr_number"
  fi

  # 2. Close PR
  if gh pr close "$pr_number" 2>/dev/null; then
    print_info "Closed PR #$pr_number"
  else
    print_warning "Failed to close PR #$pr_number"
  fi

  # 3. Exit worktree before removing it
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || cd "$HOME"

  # 4. Remove worktree
  if git worktree remove "$worktree_path" --force 2>/dev/null; then
    print_info "Removed worktree: $(basename "$worktree_path")"
  else
    print_warning "Failed to remove worktree: $worktree_path"
  fi

  # 5. Delete local branch
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git branch -D "$branch_name" 2>/dev/null || true
    print_info "Deleted local branch: $branch_name"
  fi

  # 6. Delete remote branch
  if git push origin --delete "$branch_name" 2>/dev/null; then
    print_info "Deleted remote branch: $branch_name"
  fi

  # 7. Remove session state file
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR:-.rite}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    print_info "Removed session state"
  fi

  print_success "Stale branch cleanup complete — restarting fresh"
  return 0
}

# ===================================================================
# INTERNAL: Supervised mode prompt
# ===================================================================

# _stale_supervised_prompt WORKTREE_PATH PR_NUMBER ISSUE_NUMBER BRANCH_NAME COMMITS_BEHIND
_stale_supervised_prompt() {
  local worktree_path="$1"
  local pr_number="$2"
  local issue_number="$3"
  local branch_name="$4"
  local behind="$5"

  # Gather info for report
  local last_commit_date
  last_commit_date=$(git -C "$worktree_path" log -1 --format='%ci' HEAD 2>/dev/null | cut -d' ' -f1)
  local commit_count
  commit_count=$(git -C "$worktree_path" log --oneline origin/main..HEAD 2>/dev/null | wc -l | tr -d ' ')

  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}Branch Staleness Report${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  Branch:        $branch_name"
  echo "  PR:            #$pr_number"
  echo "  Behind main:   $behind commits"
  echo "  Last activity: $last_commit_date"
  echo "  Branch work:   $commit_count commit(s)"
  echo ""
  print_warning "This branch is significantly behind main."
  echo ""
  echo "  Recommended: Close PR and restart fresh."
  echo "  The final merge is a squash, so merge commits don't pollute history."
  echo ""
  echo "Options:"
  echo "  1) Close PR and restart fresh (recommended)"
  echo "  2) Merge main into branch"
  echo "  3) Continue without merging main (not recommended)"
  echo "  4) Abort"
  echo ""
  read -p "Choose [1/2/3/4]: " -n 1 -r
  echo

  case "$REPLY" in
    1)
      print_status "Closing PR and cleaning up for fresh start..."
      _stale_close_and_cleanup "$pr_number" "$issue_number" "$worktree_path" "$branch_name" "$behind"
      return 10
      ;;
    2)
      print_status "Merging main into branch..."
      _stale_merge_main "$worktree_path" "$branch_name" "supervised"
      return $?
      ;;
    3)
      print_warning "Continuing without merging main — code may be based on stale main"
      return 0
      ;;
    4|*)
      print_info "Workflow aborted by user"
      return 1
      ;;
  esac
}
