#!/bin/bash
# lib/utils/stale-branch.sh
# Stale branch detection and handling.
# Checks how far a feature branch is behind origin/main and responds:
#   - Below threshold: rebase branch onto origin/main (replays commits on fresh main)
#   - At/above threshold: close PR, cleanup, signal fresh restart
#
# Threshold controlled by RITE_STALE_BRANCH_THRESHOLD (default: 10 commits).
# Rebase avoids false conflicts from merge when main has added files since branch creation.

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

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
    # Below threshold: rebase branch onto main (replays branch commits on top of current main)
    # This avoids false conflicts from merge when main has added new files since branch creation
    print_info "Branch is $behind commit(s) behind main (threshold: $threshold) — rebasing onto main"
    _stale_rebase_onto_main "$worktree_path" "$branch_name" "$workflow_mode"
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
  changed_files=$(git -C "$worktree_path" diff --name-only origin/main...HEAD 2>/dev/null || echo "(none)")

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
# INTERNAL: Rebase branch onto main
# ===================================================================

# _stale_rebase_onto_main WORKTREE_PATH BRANCH_NAME WORKFLOW_MODE
#
# Rebases the feature branch onto origin/main. Replays branch commits on top of current main.
# Requires force-push with --force-with-lease after successful rebase (history is rewritten).
_stale_rebase_onto_main() {
  local worktree_path="$1"
  local branch_name="$2"
  local workflow_mode="$3"

  cd "$worktree_path" || return 1

  # Count commits to report progress - how many commits will be replayed
  local commits_ahead
  commits_ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")

  # Stash dirty worktree if needed
  local _stashed=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    print_status "Stashing uncommitted changes before rebase..."
    git stash push -m "stale-branch: auto-stash before rebase main" 2>/dev/null || true
    _stashed=true
  fi

  print_status "Rebasing branch onto origin/main ($commits_ahead commits ahead, replaying onto fresh main)..."

  local rebase_output
  if rebase_output=$(git rebase origin/main 2>&1); then
    # Rebase succeeded — restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || {
        print_warning "Stash pop had conflicts — stash preserved (run 'git stash pop' manually)"
      }
    fi

    # Verify rebase didn't introduce silent semantic conflicts (tests pass)
    if ! verify_post_merge "$worktree_path"; then
      print_warning "Rebase succeeded at git level but tests fail — possible semantic conflict"
      git rebase --abort 2>/dev/null || true
      if [ "$workflow_mode" = "supervised" ]; then
        echo "" >&2
        echo "The rebase onto main introduced test failures." >&2
        echo "Options:" >&2
        echo "  c) Continue without rebasing onto main (keep working on stale branch)" >&2
        echo "  d) Abort workflow" >&2
        read -p "Choose [c/d]: " -n 1 -r >&2
        echo >&2
        case "$REPLY" in
          c|C) return 0 ;;
          *)   return 1 ;;
        esac
      else
        print_error "Post-rebase verification failed — cannot proceed in auto mode"
        print_info "Run 'rite \$issue_number --supervised' to resolve manually"
        return 1
      fi
    fi

    # Push with force-with-lease (history was rewritten by rebase)
    # --force-with-lease is safer than --force: only succeeds if remote hasn't changed
    if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
      print_success "Branch rebased onto origin/main"
      return 0
    else
      print_error "Push failed after rebase (force-with-lease rejected)"
      return 1
    fi
  else
    # Rebase had conflicts — abort it
    print_warning "Rebase onto main had conflicts"
    git rebase --abort 2>/dev/null || true

    # Restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || true
    fi

    if [ "$workflow_mode" = "supervised" ]; then
      echo "" >&2
      echo "Conflicting with main. Options:" >&2
      echo "  c) Continue without rebasing onto main (not recommended)" >&2
      echo "  d) Abort workflow" >&2
      read -p "Choose [c/d]: " -n 1 -r >&2
      echo >&2
      case "$REPLY" in
        c|C) return 0 ;;
        *)   return 1 ;;
      esac
    else
      print_error "Rebase onto main failed (conflicts) — cannot proceed in auto mode"
      print_info "Run 'rite \$issue_number --supervised' to resolve manually"
      return 1
    fi
  fi
}

# _stale_merge_main_legacy WORKTREE_PATH BRANCH_NAME WORKFLOW_MODE
#
# Legacy merge-based update (opt-in via supervised mode).
# Merges origin/main into the feature branch. Same as GitHub "Update branch".
# No force-push needed — history isn't rewritten, regular git push works.
_stale_merge_main_legacy() {
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

    # Verify merge didn't introduce silent semantic conflicts (tests pass)
    if ! verify_post_merge "$worktree_path"; then
      print_warning "Merge succeeded at git level but tests fail — possible semantic conflict"
      git reset --hard HEAD~1 2>/dev/null || true
      if [ "$workflow_mode" = "supervised" ]; then
        echo "" >&2
        echo "The merge with main introduced test failures." >&2
        echo "Options:" >&2
        echo "  c) Continue without merging main (keep working on stale branch)" >&2
        echo "  d) Abort workflow" >&2
        read -p "Choose [c/d]: " -n 1 -r >&2
        echo >&2
        case "$REPLY" in
          c|C) return 0 ;;
          *)   return 1 ;;
        esac
      else
        print_error "Post-merge verification failed — cannot proceed in auto mode"
        print_info "Run 'rite \$issue_number --supervised' to resolve manually"
        return 1
      fi
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

  # Use temp file to avoid shell metacharacter issues in body
  local comment_file
  comment_file=$(mktemp)
  printf '%s' "$comment_body" > "$comment_file"
  if ! gh pr comment "$pr_number" --body-file "$comment_file" 2>/dev/null; then
    print_warning "Failed to post close comment on PR #$pr_number"
  fi
  rm -f "$comment_file"

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
  echo "  2) Rebase branch onto main (recommended update method)"
  echo "  3) Merge main into branch (legacy, may cause false conflicts)"
  echo "  4) Continue without updating (not recommended)"
  echo "  5) Abort"
  echo ""
  read -p "Choose [1/2/3/4/5]: " -n 1 -r
  echo

  case "$REPLY" in
    1)
      print_status "Closing PR and cleaning up for fresh start..."
      _stale_close_and_cleanup "$pr_number" "$issue_number" "$worktree_path" "$branch_name" "$behind"
      return 10
      ;;
    2)
      print_status "Rebasing branch onto main..."
      _stale_rebase_onto_main "$worktree_path" "$branch_name" "supervised"
      return $?
      ;;
    3)
      print_status "Merging main into branch (legacy mode)..."
      _stale_merge_main_legacy "$worktree_path" "$branch_name" "supervised"
      return $?
      ;;
    4)
      print_warning "Continuing without updating — code may be based on stale main"
      return 0
      ;;
    5|*)
      print_info "Workflow aborted by user"
      return 1
      ;;
  esac
}
