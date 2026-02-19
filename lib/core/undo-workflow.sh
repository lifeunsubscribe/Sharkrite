#!/bin/bash
# undo-workflow.sh
# Undo a rite workflow: close PR, clean up follow-ups, worktree, branches, state
#
# Usage:
#   undo-workflow.sh <ISSUE_NUMBER>
#
# Only works if the PR has NOT been merged. Always interactive (requires y/n).
# Best-effort cleanup: warns on individual failures, continues with rest.

set -euo pipefail

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

ISSUE_NUMBER="${1:-}"

if [ -z "$ISSUE_NUMBER" ]; then
  print_error "Usage: rite <issue> --undo"
  exit 1
fi

if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]] || [ "$ISSUE_NUMBER" -le 0 ] 2>/dev/null; then
  print_error "Invalid issue number: $ISSUE_NUMBER"
  exit 1
fi

# =============================================================================
# PHASE 1: DISCOVERY
# =============================================================================

print_header "🔄 Undo Workflow for Issue #$ISSUE_NUMBER"
echo ""

STATE_FILE="$RITE_PROJECT_ROOT/${RITE_DATA_DIR:-.rite}/session-state-${ISSUE_NUMBER}.json"

# --- 1.1: Find the PR ---

PR_NUMBER=""
PR_STATE=""
PR_BRANCH=""

# Try session state first
if [ -f "$STATE_FILE" ]; then
  PR_NUMBER=$(jq -r '.pr_number // empty' "$STATE_FILE" 2>/dev/null || echo "")
  [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""
fi

# Fall back to GitHub search (body text)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr list --state all --json number,body --limit 100 2>/dev/null | \
    jq --arg issue "$ISSUE_NUMBER" -r \
    '[.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b"))] | .[0].number // empty' \
    2>/dev/null || echo "")
  [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""
fi

# Fall back to title matching (create-pr.sh overwrites the body, dropping the issue reference)
if [ -z "$PR_NUMBER" ]; then
  ISSUE_TITLE=$(gh issue view "$ISSUE_NUMBER" --json title --jq '.title' 2>/dev/null || echo "")
  if [ -n "$ISSUE_TITLE" ] && [ "$ISSUE_TITLE" != "null" ]; then
    PR_NUMBER=$(gh pr list --state all --json number,title --limit 100 2>/dev/null | \
      jq --arg title "$ISSUE_TITLE" -r \
      '[.[] | select(.title | ascii_downcase == ($title | ascii_downcase))] | .[0].number // empty' \
      2>/dev/null || echo "")
    [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""
  fi
fi

if [ -n "$PR_NUMBER" ]; then
  PR_DATA=$(gh pr view "$PR_NUMBER" --json state,headRefName,mergedAt 2>/dev/null || echo "")
  if [ -n "$PR_DATA" ]; then
    PR_STATE=$(echo "$PR_DATA" | jq -r '.state')
    PR_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')

    # Hard stop if merged
    if [ "$PR_STATE" = "MERGED" ]; then
      print_error "PR #$PR_NUMBER has already been merged"
      print_info "Cannot undo a merged PR. Use 'git revert' instead."
      exit 1
    fi
  fi
fi

# --- 1.2: Find follow-up/tech-debt issues ---

FOLLOWUP_ISSUES=()

if [ -n "$PR_NUMBER" ]; then
  # Method 1: Issues with label "parent-pr:{PR}"
  while IFS= read -r num; do
    [ -n "$num" ] && FOLLOWUP_ISSUES+=("$num")
  done < <(gh issue list --label "parent-pr:$PR_NUMBER" --state all --json number --jq '.[].number' 2>/dev/null || echo "")

  # Method 2: PR comment markers <!-- sharkrite-followup-issue:N -->
  while IFS= read -r num; do
    [ -n "$num" ] && FOLLOWUP_ISSUES+=("$num")
  done < <(gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body' 2>/dev/null | \
    grep -oE 'sharkrite-followup-issue:[0-9]+' | cut -d: -f2 || echo "")

  # Deduplicate
  if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
    FOLLOWUP_ISSUES=($(printf '%s\n' "${FOLLOWUP_ISSUES[@]}" | sort -un))
  fi
fi

# --- 1.3: Find worktree ---

WORKTREE_PATH=""

# Try session state
if [ -f "$STATE_FILE" ]; then
  WORKTREE_PATH=$(jq -r '.worktree_path // empty' "$STATE_FILE" 2>/dev/null || echo "")
  [ "$WORKTREE_PATH" = "null" ] && WORKTREE_PATH=""
  # Verify it exists
  [ -n "$WORKTREE_PATH" ] && [ ! -d "$WORKTREE_PATH" ] && WORKTREE_PATH=""
fi

# Fall back to git worktree list
if [ -z "$WORKTREE_PATH" ] && [ -n "$PR_BRANCH" ]; then
  WORKTREE_PATH=$(git worktree list 2>/dev/null | grep "\[$PR_BRANCH\]" | awk '{print $1}' || echo "")
fi

# --- 1.4: Check local branch ---

LOCAL_BRANCH_EXISTS=false
BRANCH_NAME="${PR_BRANCH:-}"

# If no PR branch, try to infer from worktree
if [ -z "$BRANCH_NAME" ] && [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ]; then
  BRANCH_NAME=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null || echo "")
fi

if [ -n "$BRANCH_NAME" ]; then
  git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null && LOCAL_BRANCH_EXISTS=true
fi

# --- 1.5: Check local state files ---

SESSION_STATE_EXISTS=false
[ -f "$STATE_FILE" ] && SESSION_STATE_EXISTS=true


# --- 1.6: Check original issue state ---

ISSUE_STATE=""
ISSUE_TITLE=""
ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --json state,title 2>/dev/null || echo "")
if [ -n "$ISSUE_DATA" ]; then
  ISSUE_STATE=$(echo "$ISSUE_DATA" | jq -r '.state')
  ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')
fi

# =============================================================================
# PHASE 2: CONFIRMATION
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Undo Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Issue:  #$ISSUE_NUMBER${ISSUE_TITLE:+ - $ISSUE_TITLE}"
echo ""

# PR
if [ -n "$PR_NUMBER" ]; then
  if [ "$PR_STATE" = "OPEN" ]; then
    echo "  PR #$PR_NUMBER .............. revert to draft + reset branch to main"
  elif [ "$PR_STATE" = "CLOSED" ]; then
    echo "  PR #$PR_NUMBER .............. already closed (skip)"
  fi
else
  echo "  PR ...................... not found (skip)"
fi

# Review comments
if [ -n "$PR_NUMBER" ]; then
  echo "  Review comments ......... delete sharkrite comments"
else
  echo "  Review comments ......... no PR (skip)"
fi

# Follow-up issues
if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
  echo "  Follow-up issues ........ close ${#FOLLOWUP_ISSUES[@]}: $(printf '#%s ' "${FOLLOWUP_ISSUES[@]}")"
else
  echo "  Follow-up issues ........ none found"
fi

# Worktree
if [ -n "$WORKTREE_PATH" ]; then
  echo "  Worktree ................ remove $(basename "$WORKTREE_PATH")"
else
  echo "  Worktree ................ not found (skip)"
fi

# Local branch
if [ "$LOCAL_BRANCH_EXISTS" = true ]; then
  echo "  Local branch ............ delete $BRANCH_NAME"
else
  echo "  Local branch ............ not found (skip)"
fi

# State files
if [ "$SESSION_STATE_EXISTS" = true ]; then
  echo "  Local state files ....... remove"
else
  echo "  Local state files ....... none found"
fi

# Scratchpad
echo "  Scratchpad .............. clear Current Work"

# Original issue
if [ "$ISSUE_STATE" = "closed" ] || [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "  Issue #$ISSUE_NUMBER ............. reopen"
elif [ "$ISSUE_STATE" = "open" ] || [ "$ISSUE_STATE" = "OPEN" ]; then
  echo "  Issue #$ISSUE_NUMBER ............. already open (skip)"
fi

echo ""
read -p "Proceed with undo? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  print_info "Undo cancelled"
  exit 0
fi

# =============================================================================
# PHASE 3: EXECUTION
# =============================================================================

UNDO_ERRORS=0
echo ""

# --- 3.1: Close PR ---

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔒 PR Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -n "$PR_NUMBER" ] && [ "$PR_STATE" = "OPEN" ]; then
  # Revert to draft instead of closing — avoids PR number stacking on rerun.
  # The next `rite` run finds the existing draft PR and reuses it.
  if gh pr ready --undo "$PR_NUMBER" 2>/dev/null; then
    print_success "Reverted PR #$PR_NUMBER to draft"
  else
    print_info "PR #$PR_NUMBER may already be a draft"
  fi

  # Reset the remote branch to main's HEAD (clean code slate).
  # The draft PR stays linked to this branch; next run pushes new work to it.
  if [ -n "$BRANCH_NAME" ]; then
    if git push origin "main:refs/heads/$BRANCH_NAME" --force 2>/dev/null; then
      print_success "Reset remote branch to main (clean slate)"
      # Update local tracking ref so next run sees the reset (avoids stale origin/branch
      # causing non-fast-forward push → branch deletion → PR closure → new PR)
      git fetch origin "$BRANCH_NAME" 2>/dev/null || true
    else
      print_warning "Failed to reset remote branch"
      UNDO_ERRORS=$((UNDO_ERRORS + 1))
    fi
  fi
elif [ -n "$PR_NUMBER" ] && [ "$PR_STATE" = "CLOSED" ]; then
  print_info "PR #$PR_NUMBER already closed"
  # Delete orphaned remote branch if it still exists
  if [ -n "$BRANCH_NAME" ]; then
    if git push origin --delete "$BRANCH_NAME" 2>/dev/null; then
      print_success "Deleted orphaned remote branch: $BRANCH_NAME"
    else
      print_info "Remote branch already deleted or not found"
    fi
  fi
else
  print_info "No PR to reset"
fi

# --- 3.2: Delete sharkrite review and assessment comments ---

if [ -n "$PR_NUMBER" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧹 Review Cleanup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

  if [ -n "$REPO" ]; then
    # Delete sharkrite PR comments (reviews + assessments are all posted as comments)
    COMMENT_IDS=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate --jq \
      '.[] | select(.body | contains("sharkrite-local-review") or contains("sharkrite-assessment")) | .id' 2>/dev/null || echo "")

    DELETED_COMMENTS=0
    for cid in $COMMENT_IDS; do
      if gh api "repos/$REPO/issues/comments/$cid" -X DELETE 2>/dev/null; then
        DELETED_COMMENTS=$((DELETED_COMMENTS + 1))
      fi
    done

    if [ $DELETED_COMMENTS -gt 0 ]; then
      print_success "Removed $DELETED_COMMENTS comment(s)"
    else
      print_info "No sharkrite comments found to clean up"
    fi
  else
    print_warning "Could not determine repo - skipping review cleanup"
    UNDO_ERRORS=$((UNDO_ERRORS + 1))
  fi
fi

# --- 3.3: Close follow-up issues ---

if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 Follow-up Issue Cleanup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  for issue_num in "${FOLLOWUP_ISSUES[@]}"; do
    local_state=$(gh issue view "$issue_num" --json state --jq '.state' 2>/dev/null || echo "")
    if [ "$local_state" = "OPEN" ]; then
      if gh issue close "$issue_num" --comment "Closed by undo of issue #$ISSUE_NUMBER (PR #${PR_NUMBER:-unknown})" 2>/dev/null; then
        print_success "Closed follow-up issue #$issue_num"
      else
        print_warning "Failed to close follow-up issue #$issue_num"
        UNDO_ERRORS=$((UNDO_ERRORS + 1))
      fi
    else
      print_info "Follow-up issue #$issue_num already closed"
    fi
  done
fi

# --- 3.4: Remove worktree ---

if [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🗂️  Worktree Cleanup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Make sure we're not inside the worktree
  CURRENT_DIR=$(pwd)
  if [[ "$CURRENT_DIR" == "$WORKTREE_PATH"* ]]; then
    print_status "Switching to project root..."
    cd "$RITE_PROJECT_ROOT"
  fi

  if git worktree remove "$WORKTREE_PATH" --force 2>/dev/null; then
    print_success "Removed worktree: $(basename "$WORKTREE_PATH")"
  else
    print_warning "Failed to remove worktree: $WORKTREE_PATH"
    print_info "Try manually: git worktree remove '$WORKTREE_PATH' --force"
    UNDO_ERRORS=$((UNDO_ERRORS + 1))
  fi
fi

# --- 3.5: Delete local branch ---

if [ "$LOCAL_BRANCH_EXISTS" = true ] && [ -n "$BRANCH_NAME" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🌿 Branch Cleanup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Make sure we're not on the branch being deleted
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [ "$CURRENT_BRANCH" = "$BRANCH_NAME" ]; then
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
  fi

  if git branch -D "$BRANCH_NAME" >/dev/null 2>&1; then
    print_success "Deleted local branch: $BRANCH_NAME"
  else
    print_warning "Failed to delete local branch: $BRANCH_NAME"
    UNDO_ERRORS=$((UNDO_ERRORS + 1))
  fi
fi

# --- 3.6: Remove local state files ---

if [ "$SESSION_STATE_EXISTS" = true ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🗑️  State Cleanup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  rm -f "$STATE_FILE"
  print_success "Removed session state"
fi

# --- 3.7: Clear scratchpad ---

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Scratchpad Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if type clear_current_work &>/dev/null; then
  clear_current_work >/dev/null 2>&1
  print_success "Cleared Current Work section"
else
  print_info "No scratchpad to clear"
fi

# --- 3.8: Reopen original issue ---

if [ "$ISSUE_STATE" = "closed" ] || [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔓 Issue Restore"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if gh issue reopen "$ISSUE_NUMBER" --comment "Reopened by undo (PR #${PR_NUMBER:-unknown} was closed without merging)" 2>/dev/null; then
    print_success "Reopened issue #$ISSUE_NUMBER"
  else
    print_warning "Failed to reopen issue #$ISSUE_NUMBER"
    UNDO_ERRORS=$((UNDO_ERRORS + 1))
  fi
fi

# =============================================================================
# PHASE 4: SUMMARY
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $UNDO_ERRORS -eq 0 ]; then
  echo "✅ Undo Complete"
else
  echo "⚠️  Undo Complete ($UNDO_ERRORS warning(s))"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Issue #$ISSUE_NUMBER is ready to be re-worked."
if [ -n "$PR_NUMBER" ] && [ "$PR_STATE" = "OPEN" ]; then
  echo "  PR #$PR_NUMBER preserved as draft (will be reused on next run)."
fi
echo "  Run 'rite $ISSUE_NUMBER' to start fresh."
echo ""

exit 0
