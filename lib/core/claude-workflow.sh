#!/bin/bash
# scripts/claude-workflow.sh
# Unified workflow entry point - handles all modes of starting/continuing work
#
# Usage Examples:
#   forge 19                            # From GitHub issue (supervised)
#   forge 19 --quick                    # From GitHub issue (unsupervised)
#   forge "add oauth"                   # From description (supervised)
#   forge --continue                    # Continue work on existing branch
#
# Features:
#   - Smart worktree detection (auto-navigates to existing worktrees)
#   - Automatic stashing/unstashing
#   - Auto-cleanup at worktree limit (merged branches, stale worktrees)
#   - Scratchpad integration (loads recent security findings)
#   - Zero unnecessary prompts (only ambiguity or genuine blockers)

set -euo pipefail

# Source config if not already loaded
if [ -z "${FORGE_LIB_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Source session tracker for interrupt state saving
source "$FORGE_LIB_DIR/utils/session-tracker.sh"

# Store the absolute path to THIS script for re-execution
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Early output to confirm script is running
echo "🚀 Claude Workflow Starting..."
echo ""

# Trap handler for safe exit on interrupt
cleanup_on_interrupt() {
  local exit_code=$?

  echo ""
  echo -e "\033[1;33m⚠️  Workflow interrupted!\033[0m"

  # Check if we're in a worktree
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    local current_dir=$(pwd)
    local main_repo
    main_repo=$(git worktree list | head -1 | awk '{print $1}')

    # Check for uncommitted changes (exclude untracked files)
    local uncommitted
    uncommitted=$(git status --porcelain | grep -vE "^\?\?" | wc -l | tr -d ' ')

    if [ "$uncommitted" -gt 0 ]; then
      echo -e "\033[0;34mℹ️  Found $uncommitted uncommitted change(s)\033[0m"

      if [ "$AUTO_MODE" = true ]; then
        # In auto mode, always commit WIP
        local branch_name
        branch_name=$(git branch --show-current)
        local commit_msg="WIP: interrupted work on ${branch_name}"

        git add -A
        git commit -m "$commit_msg" 2>/dev/null || true
        echo -e "\033[0;32m✅ Changes committed: $commit_msg\033[0m"

        # Push in auto mode
        git push -u origin "$branch_name" 2>/dev/null || echo -e "\033[1;33m⚠️  Push failed (changes are committed locally)\033[0m"
      else
        # In supervised mode, ask the user
        read -p "Commit changes before exiting? (y/n) " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
          local branch_name
          branch_name=$(git branch --show-current)
          local commit_msg="WIP: interrupted work on ${branch_name}"

          git add -A
          git commit -m "$commit_msg" 2>/dev/null || true
          echo -e "\033[0;32m✅ Changes committed\033[0m"

          read -p "Push to remote? (y/n) " -n 1 -r
          echo
          if [[ $REPLY =~ ^[Yy]$ ]]; then
            git push -u origin "$branch_name" 2>/dev/null || echo -e "\033[1;33m⚠️  Push failed\033[0m"
          fi
        fi
      fi
    fi

    # Save session state for resume if we have enough context
    if [ -n "${ISSUE_NUMBER:-}" ] && [ -n "$current_dir" ]; then
      save_session_state "${ISSUE_NUMBER}" "interrupted" "$current_dir" 2>/dev/null || true
      echo -e "\033[0;34mℹ️  Session state saved — run 'forge ${ISSUE_NUMBER}' to resume\033[0m"
    fi

    # Navigate back to main repo if in worktree
    if [ -n "$main_repo" ] && [ "$current_dir" != "$main_repo" ]; then
      echo -e "\033[0;34mℹ️  Returning to main repository...\033[0m"
      cd "$main_repo" || cd "$HOME"
      echo -e "\033[0;32m✅ Exited worktree: $current_dir\033[0m"
      echo -e "\033[0;34mℹ️  Your work is preserved in the worktree\033[0m"
    fi
  fi

  exit ${exit_code}
}

trap cleanup_on_interrupt INT TERM

# Parse arguments - Two-pass to detect flags before processing issue number
AUTO_MODE=false
FIX_REVIEW_MODE=false
ISSUE_NUMBER=""
ISSUE_DESC=""

# First pass: detect flags
for arg in "$@"; do
  case $arg in
    --auto) AUTO_MODE=true ;;
    --fix-review) FIX_REVIEW_MODE=true ;;
  esac
done

# Second pass: process issue number or description
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto|--fix-review)
      # Already processed in first pass
      shift
      ;;
    *)
      # In fix-review mode, skip GitHub API calls (we only need issue number)
      if [ "$FIX_REVIEW_MODE" = true ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_NUMBER="$1"
        shift
      # Normal mode: fetch issue details from GitHub
      elif [[ "$1" =~ ^[0-9]+$ ]]; then
        # Validate issue number is a positive integer
        if [ "$1" -le 0 ] 2>/dev/null; then
          echo "❌ Invalid issue number: $1 (must be positive integer)"
          exit 1
        fi
        ISSUE_NUMBER="$1"
        echo "▶  Fetching issue #$ISSUE_NUMBER from GitHub..."
        # Fetch issue details from GitHub
        ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --json title,body 2>/dev/null || echo "")
        if [ -n "$ISSUE_JSON" ] && [ "$ISSUE_JSON" != "null" ]; then
          ISSUE_DESC=$(echo "$ISSUE_JSON" | jq -r '.title')
          echo "✅ Issue loaded: $ISSUE_DESC"
        else
          echo "❌ Issue #$ISSUE_NUMBER not found on GitHub"
          exit 1
        fi
        shift
      else
        ISSUE_DESC="$1"
        shift
      fi
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_step() { echo -e "${CYAN}▶  $1${NC}"; }

# ===================================================================
# EARLY EXIT FOR FIX-REVIEW MODE
# Must run before any worktree navigation to preserve stdin
# ===================================================================
if [ "$FIX_REVIEW_MODE" = true ]; then
  # Jump directly to fix-review logic (defined later in file)
  # We need to source the CLAUDE_CMD variable first
  if command -v claude &> /dev/null; then
    CLAUDE_CMD="claude"
  elif [ -f "$HOME/.claude/claude" ]; then
    CLAUDE_CMD="$HOME/.claude/claude"
  else
    print_error "Claude CLI not found"
    print_info "Please install Claude CLI: https://github.com/anthropics/claude-cli"
    exit 1
  fi

  # Now run the fix-review logic inline
  print_header "🔧 Review Fix Mode"

  # Read review content from stdin
  print_info "Reading review content from stdin..."
  REVIEW_CONTENT=$(cat)

  if [ -z "$REVIEW_CONTENT" ]; then
    print_error "No review content received via stdin"
    exit 1
  fi

  print_info "Review content received ($(echo "$REVIEW_CONTENT" | wc -l) lines)"

  # Extract all ACTIONABLE issues (regardless of priority)
  # The filtered review will only contain items Claude assessed as ACTIONABLE
  CRITICAL_ISSUES=$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' | grep -E '^### [0-9]+\.' || echo "")
  HIGH_ISSUES=$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Hh]igh/,/^##[^#]/p' | grep -E '^### [0-9]+\.' || echo "")
  MEDIUM_ISSUES=$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Mm]edium/,/^##[^#]/p' | grep -E '^### [0-9]+\.' || echo "")
  LOW_ISSUES=$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Ll]ow/,/^##[^#]/p' | grep -E '^### [0-9]+\.' || echo "")

  # Build fix prompt
  FIX_PROMPT="## Review Issues to Fix

The automated PR review found issues that need to be addressed. Please fix ALL of the following ACTIONABLE items:

"

  if [ -n "$CRITICAL_ISSUES" ]; then
    FIX_PROMPT+="### CRITICAL Issues

$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Cc]ritical/,/^##[^#]/p')

"
  fi

  if [ -n "$HIGH_ISSUES" ]; then
    FIX_PROMPT+="### HIGH Priority Issues

$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Hh]igh/,/^##[^#]/p')

"
  fi

  if [ -n "$MEDIUM_ISSUES" ]; then
    FIX_PROMPT+="### MEDIUM Priority Issues

$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Mm]edium/,/^##[^#]/p')

"
  fi

  if [ -n "$LOW_ISSUES" ]; then
    FIX_PROMPT+="### LOW Priority Issues

$(echo "$REVIEW_CONTENT" | sed -n '/^## .*[Ll]ow/,/^##[^#]/p')

"
  fi

  FIX_PROMPT+="## Instructions

1. **Read the review issues above carefully**
2. **Fix each issue** - make the necessary code changes
3. **Verify your fixes** - ensure the changes address the concerns
4. **Exit immediately** after fixing by typing \`/quit\` or \`/exit\`

The workflow will automatically commit, push, and wait for a new review.

**IMPORTANT**: Focus only on the issues listed above. Do not make unrelated changes."

  print_info "Invoking Claude Code to fix review issues..."
  echo ""

  # Run Claude Code with the fix prompt
  # Use printf instead of echo for safety with untrusted content
  # This prevents any potential shell interpretation of special characters
  if [ "$AUTO_MODE" = true ]; then
    printf '%s\n' "$FIX_PROMPT" | $CLAUDE_CMD --permission-mode bypassPermissions
  else
    printf '%s\n' "$FIX_PROMPT" | $CLAUDE_CMD
  fi

  print_success "Review issues fixed"

  # Commit and push the fixes
  print_info "Committing fixes..."
  git add -A

  # Generate commit message based on review content summary
  COMMIT_MSG="fix: address review findings from PR automated review

Auto-generated commit addressing issues identified in PR review.
See PR comments for detailed list of fixes applied.

Changes made via automated workflow (forge --fix-review mode)."

  git commit -m "$COMMIT_MSG" || {
    print_error "No changes to commit"
    exit 1
  }

  print_info "Pushing fixes to remote..."
  git push

  print_success "Fixes committed and pushed successfully"
  exit 0
fi

# Find worktree for given issue number
# Returns: "worktree_path|branch_name" or empty string
find_worktree_for_task() {
  local task="$1"  # Could be issue number OR description
  local result=""
  local pr_branch=""

  # If task is a number, it's an issue number - search by linked PR
  if [[ "$task" =~ ^[0-9]+$ ]]; then
    # Check if this is a follow-up issue with parent PR
    local issue_labels=$(gh issue view "$task" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

    if echo "$issue_labels" | grep -q "parent-pr:"; then
      # Extract parent PR number and use its branch
      local parent_pr=$(echo "$issue_labels" | grep -oE 'parent-pr:[0-9]+' | cut -d: -f2)

      if [ -n "$parent_pr" ]; then
        pr_branch=$(gh pr view "$parent_pr" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

        if [ -n "$pr_branch" ] && [ "$pr_branch" != "null" ]; then
          # Found parent PR's branch - this follow-up should work on same branch
          # Continue below to find worktree
          :
        fi
      fi
    fi

    # If not a follow-up or couldn't find parent, use normal logic
    if [ -z "$pr_branch" ] || [ "$pr_branch" = "null" ]; then
      # Get issue title for better PR matching
      local issue_title=$(gh issue view "$task" --json title --jq '.title' 2>/dev/null || echo "")

      # Try to find PR linked to this issue (searches body for "Closes #XX" pattern)
      # NOTE: GitHub search doesn't support exact pattern matching, so we fetch all PRs and filter
      pr_branch=$(gh pr list --state all --json headRefName,body --limit 100 2>/dev/null | \
        jq --arg issue "$task" -r '.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .headRefName' | \
        head -1)

      # If no PR found by issue link, try title matching
      if [ -z "$pr_branch" ] || [ "$pr_branch" = "null" ]; then
        if [ -n "$issue_title" ] && [ "$issue_title" != "null" ]; then
          pr_branch=$(gh pr list --json headRefName,title --limit 50 2>/dev/null | \
            jq --arg title "$issue_title" -r '.[] | select(.title | ascii_downcase | contains($title | ascii_downcase)) | .headRefName' | \
            head -1)
        fi
      fi
    fi
  else
    # Task is a description - search PRs by title similarity
    pr_branch=$(gh pr list --json headRefName,title --limit 50 2>/dev/null | \
      jq --arg title "$task" -r '.[] | select(.title | ascii_downcase | contains($title | ascii_downcase)) | .headRefName' | \
      head -1)
  fi

  # If we found a PR, find the worktree with that branch
  if [ -n "$pr_branch" ] && [ "$pr_branch" != "null" ]; then
    while IFS= read -r worktree_line; do
      local wt_path=$(echo "$worktree_line" | awk '{print $1}')
      local wt_branch=$(echo "$worktree_line" | grep -oE '\[[^]]+\]' | tr -d '[]' || echo "")

      if [ "$wt_branch" = "$pr_branch" ]; then
        result="${wt_path}|${wt_branch}"
        break
      fi
    done < <(git worktree list | tail -n +2)
  fi

  echo "$result"
}

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

CLAUDE_CMD="npx @anthropic-ai/claude-code"
if command -v claude-code &> /dev/null; then
  CLAUDE_CMD="claude-code"
fi

CURRENT_BRANCH=$(git branch --show-current)

# Check if already in a worktree
MAIN_WORKTREE=$(git rev-parse --show-toplevel)
IS_MAIN_WORKTREE=false
# Defensive check: grep can return 1 if no match, which would exit script with set -e
if git worktree list | grep -q "^$(git rev-parse --show-toplevel).*\[main\]" || [[ "$CURRENT_BRANCH" == "main" ]]; then
  IS_MAIN_WORKTREE=true
fi

# Smart worktree detection and navigation
# Try to find existing worktree by issue number or description
TASK_IDENTIFIER="${ISSUE_NUMBER:-$ISSUE_DESC}"
if [ -n "$TASK_IDENTIFIER" ]; then
  WORKTREE_INFO=$(find_worktree_for_task "$TASK_IDENTIFIER")

  if [ -n "$WORKTREE_INFO" ]; then
    # Found existing worktree - navigate there
    TARGET_WORKTREE=$(echo "$WORKTREE_INFO" | cut -d'|' -f1)
    TARGET_BRANCH=$(echo "$WORKTREE_INFO" | cut -d'|' -f2)

    print_success "Found existing worktree for issue #$ISSUE_NUMBER"
    print_info "Branch: $TARGET_BRANCH"
    print_info "Location: $TARGET_WORKTREE"
    echo ""
    print_info "Navigating to worktree..."

    # Re-execute script in target worktree, passing issue description to avoid losing it
    # Use cd in subshell and export vars separately to avoid command injection
    cd "$TARGET_WORKTREE" || exit 1
    export CONTINUE_ISSUE_NUM="$ISSUE_NUMBER"
    export CONTINUE_ISSUE_DESC="$ISSUE_DESC"
    if [ "$AUTO_MODE" = true ]; then
      exec "$SCRIPT_PATH" --auto
    else
      exec "$SCRIPT_PATH"
    fi
  fi
  # If not found, continue below to create new worktree
fi

# If we reach here without an issue number, we're continuing in current worktree
if [ -z "$ISSUE_NUMBER" ]; then
  print_header "🔄 Continuing in Current Worktree"

  # Check if we're on main/develop
  if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "develop" ]]; then
    print_error "Cannot work on $CURRENT_BRANCH branch"
    echo "Please provide an issue number or description"
    exit 1
  fi

  # Get issue info from environment variables (passed during navigation)
  if [ -n "${CONTINUE_ISSUE_NUM:-}" ]; then
    ISSUE_NUMBER="$CONTINUE_ISSUE_NUM"
    ISSUE_DESC="${CONTINUE_ISSUE_DESC:-Continue work on $CURRENT_BRANCH}"
  else
    # Fallback: use branch name as description
    ISSUE_DESC="Continue work on $CURRENT_BRANCH"
  fi

  BRANCH_NAME="$CURRENT_BRANCH"

  # Check for existing PR (do this for ALL continuation scenarios)
  # Check for both open and merged PRs
  PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --state all --json number,title,url,state --jq '.[0]' 2>/dev/null || echo "")
  if [ ! -z "$PR_JSON" ] && [ "$PR_JSON" != "null" ]; then
    PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
    PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
    PR_URL=$(echo "$PR_JSON" | jq -r '.url')
    PR_STATE=$(echo "$PR_JSON" | jq -r '.state')

    if [ "$PR_STATE" = "MERGED" ]; then
      print_success "✅ Work already completed!"
      echo "  PR #$PR_NUMBER: $PR_TITLE"
      echo "  Status: MERGED"
      echo "  URL: $PR_URL"
      echo ""
      print_info "Nothing to do - exiting"
      exit 0
    fi

    # PR already exists - jump directly to PR workflow
    # (workflow-runner already printed PR details to user)
    echo ""

    # Jump directly to PR workflow script - skip everything else
    if [ -f "$FORGE_LIB_DIR/core/create-pr.sh" ]; then
      if [ "$AUTO_MODE" = true ]; then
        exec "$FORGE_LIB_DIR/core/create-pr.sh" --auto
      else
        exec "$FORGE_LIB_DIR/core/create-pr.sh"
      fi
    else
      print_error "create-pr.sh not found"
      exit 1
    fi
  else
    print_info "No PR exists yet for this branch"
  fi

else
  # Create new branch or use existing branch that was found
  if [ -z "${BRANCH_NAME:-}" ]; then
    # No existing branch found - create new branch name
    if [ -z "$ISSUE_DESC" ]; then
      print_error "Usage: forge <issue-number>"
      echo "   or: forge \"issue description\""
      exit 1
    fi

    # Sanitize branch name
    SANITIZED_DESC=$(echo "$ISSUE_DESC" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | cut -c1-50)

    # Validate sanitized result
    if [ -z "$SANITIZED_DESC" ] || [ ${#SANITIZED_DESC} -lt 3 ]; then
      print_error "Invalid issue description - must contain at least 3 alphanumeric characters"
      echo "Description: \"$ISSUE_DESC\""
      echo "After sanitization: \"$SANITIZED_DESC\""
      exit 1
    fi

    # Smart prefix detection
    PREFIX="feat"
    if echo "$ISSUE_DESC" | grep -iqE '(fix|bug|issue|error)'; then
      PREFIX="fix"
    elif echo "$ISSUE_DESC" | grep -iqE '(docs|documentation|readme)'; then
      PREFIX="docs"
    elif echo "$ISSUE_DESC" | grep -iqE '(test|testing|spec)'; then
      PREFIX="test"
    elif echo "$ISSUE_DESC" | grep -iqE '(refactor|cleanup|improve)'; then
      PREFIX="refactor"
    elif echo "$ISSUE_DESC" | grep -iqE '(chore|setup|config)'; then
      PREFIX="chore"
    fi

    BRANCH_NAME="${PREFIX}/${SANITIZED_DESC}"
  fi
  # else: BRANCH_NAME already set from existing branch detection

  # Check if this branch already has a worktree before trying to create one
  EXISTING_WT_FOR_BRANCH=$(git worktree list | grep "\[$BRANCH_NAME\]" | awk '{print $1}' || echo "")
  if [ -n "$EXISTING_WT_FOR_BRANCH" ]; then
    print_success "Found existing worktree for branch $BRANCH_NAME"
    print_info "Location: $EXISTING_WT_FOR_BRANCH"
    echo ""

    # Check for uncommitted changes in the target worktree before navigating
    TARGET_UNCOMMITTED=$(git -C "$EXISTING_WT_FOR_BRANCH" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$TARGET_UNCOMMITTED" -gt 0 ]; then
      print_warning "Uncommitted changes detected in target worktree"

      # Get diff of uncommitted changes
      UNCOMMITTED_DIFF=$(git -C "$EXISTING_WT_FOR_BRANCH" diff HEAD 2>/dev/null || echo "")
      UNCOMMITTED_FILES=$(git -C "$EXISTING_WT_FOR_BRANCH" status --short 2>/dev/null || echo "")

      # Use Claude CLI to analyze if changes are relevant to the issue
      print_info "Analyzing if changes are relevant to issue #$ISSUE_NUMBER..."

      ANALYSIS_PROMPT="Issue #$ISSUE_NUMBER: $ISSUE_DESC

Uncommitted changes in worktree:
$UNCOMMITTED_FILES

Diff:
$UNCOMMITTED_DIFF

Are these changes relevant to the issue? Answer with just 'RELEVANT' or 'UNRELATED'.
If the changes are implementing or fixing something described in the issue, answer RELEVANT.
If the changes are unrelated work, answer UNRELATED."

      RELEVANCE=$(echo "$ANALYSIS_PROMPT" | claude --quiet 2>/dev/null | grep -oE "(RELEVANT|UNRELATED)" | head -1 || echo "UNKNOWN")

      if [ "$RELEVANCE" = "RELEVANT" ]; then
        # Changes are relevant - commit them
        print_success "Changes are relevant to issue #$ISSUE_NUMBER - committing..."

        cd "$EXISTING_WT_FOR_BRANCH" || exit 1
        git add -A
        COMMIT_MSG="wip: auto-commit relevant changes for issue #$ISSUE_NUMBER ($(date +%Y-%m-%d))"

        if git commit -m "$COMMIT_MSG" 2>/dev/null; then
          print_success "Changes committed: $COMMIT_MSG"
          cd - > /dev/null || exit 1
        else
          print_error "Failed to commit changes"
          cd - > /dev/null || exit 1
          print_warning "Cannot navigate to worktree with uncommitted changes"
          exit 1
        fi
      elif [ "$RELEVANCE" = "UNRELATED" ]; then
        # Changes are unrelated - stash them
        print_info "Changes are unrelated to issue #$ISSUE_NUMBER - stashing..."

        cd "$EXISTING_WT_FOR_BRANCH" || exit 1
        STASH_MSG="Auto-stash unrelated changes before issue #$ISSUE_NUMBER ($(date +%Y-%m-%d))"

        if git stash push -m "$STASH_MSG" 2>/dev/null; then
          print_success "Changes stashed: $STASH_MSG"
          print_info "Recover later with: git stash list"
          cd - > /dev/null || exit 1
        else
          print_error "Failed to stash changes"
          cd - > /dev/null || exit 1
          print_warning "Cannot navigate to worktree with uncommitted changes"
          exit 1
        fi
      else
        # Unknown - fail safe and ask user
        print_warning "Could not determine if changes are relevant"
        print_info "Uncommitted files:"
        echo "$UNCOMMITTED_FILES"
        echo ""
        print_error "Please commit or stash changes manually in: $EXISTING_WT_FOR_BRANCH"
        exit 1
      fi
    fi

    print_info "Navigating to existing worktree..."
    # Pass issue info via environment to avoid losing it
    # Use cd and export separately to avoid command injection
    cd "$EXISTING_WT_FOR_BRANCH" || exit 1
    export CONTINUE_ISSUE_NUM="$ISSUE_NUMBER"
    export CONTINUE_ISSUE_DESC="$ISSUE_DESC"
    if [ "$AUTO_MODE" = true ]; then
      exec "$SCRIPT_PATH" --auto
    else
      exec "$SCRIPT_PATH"
    fi
  fi

  print_header "🌿 Creating New Worktree"
  echo "Branch: $BRANCH_NAME"
  echo "Mode: Git Worktree (mandatory for isolation)"
  echo ""

  # Worktree mode: Create isolated working directory (MANDATORY)
  # FORGE_WORKTREE_DIR set by config.sh

  # Sanitize branch name to prevent path traversal
  # Remove: . (dot), .. (parent dir), leading/trailing slashes, multiple consecutive slashes
  SAFE_BRANCH_NAME="${BRANCH_NAME//\//-}"      # Replace / with -
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME//../-}" # Replace .. with -
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME//./}"   # Remove single dots
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME#-}"     # Remove leading dash
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME%-}"     # Remove trailing dash

  WORKTREE_PATH="$FORGE_WORKTREE_DIR/$SAFE_BRANCH_NAME"

    # Create worktrees directory if it doesn't exist
    mkdir -p "$FORGE_WORKTREE_DIR"

    # Check existing worktrees
    echo ""
    print_step "Checking existing worktrees..."

    EXISTING_WORKTREES=$(git worktree list --porcelain | grep -E "^worktree $FORGE_WORKTREE_DIR" | sed 's/^worktree //' || echo "")
    WORKTREE_COUNT=0
    MAX_WORKTREES=5

    if [ -n "$EXISTING_WORKTREES" ]; then
      echo ""
      echo "📁 Active worktrees:"

      while IFS= read -r wt_path; do
        [ -z "$wt_path" ] && continue
        WORKTREE_COUNT=$((WORKTREE_COUNT + 1))

        # Get branch name for this worktree
        WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "unknown")

        # Check for uncommitted changes
        UNCOMMITTED_COUNT=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

        # Check last modification time
        LAST_MODIFIED=$(find "$wt_path" -type f -name "*.ts" -o -name "*.js" 2>/dev/null | xargs stat -f "%m %N" 2>/dev/null | sort -rn | head -1 | awk '{print $1}')
        if [ -n "$LAST_MODIFIED" ]; then
          DAYS_OLD=$(( ( $(date +%s) - LAST_MODIFIED ) / 86400 ))
        else
          DAYS_OLD="?"
        fi

        STATUS_ICON="✓"
        if [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
          STATUS_ICON="⚠️ "
        fi

        echo "  $STATUS_ICON $WT_BRANCH - $(basename "$wt_path")"
        [ "$UNCOMMITTED_COUNT" -gt 0 ] && echo "     └─ $UNCOMMITTED_COUNT uncommitted files"
        [ "$DAYS_OLD" != "?" ] && [ "$DAYS_OLD" -gt 7 ] && echo "     └─ Last modified: $DAYS_OLD days ago"
      done <<< "$EXISTING_WORKTREES"

      echo ""

      # Check if at limit
      if [ "$WORKTREE_COUNT" -ge "$MAX_WORKTREES" ]; then
        print_warning "At worktree limit ($WORKTREE_COUNT/$MAX_WORKTREES)"
        print_info "Auto-cleanup: Looking for reusable worktrees..."

        # Find worktrees with:
        # 1. No uncommitted changes
        # 2. Branch already merged (check if exists on remote)
        # 3. Not currently in use

        CLEANED_COUNT=0
        while IFS= read -r wt_path; do
          [ -z "$wt_path" ] && continue

          WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")
          [ -z "$WT_BRANCH" ] && continue

          # Skip if has uncommitted changes
          UNCOMMITTED=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
          [ "$UNCOMMITTED" -gt 0 ] && continue

          # Check if branch is merged (not on remote anymore)
          if ! git ls-remote --heads origin "$WT_BRANCH" | grep -q "$WT_BRANCH" 2>/dev/null; then
            print_info "Cleaning merged worktree: $WT_BRANCH"
            git worktree remove "$wt_path" 2>/dev/null || true
            git branch -d "$WT_BRANCH" 2>/dev/null || true
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            [ "$CLEANED_COUNT" -ge 1 ] && break  # Only need to clean one to make room
          fi
        done <<< "$EXISTING_WORKTREES"

        if [ "$CLEANED_COUNT" -gt 0 ]; then
          print_success "Cleaned $CLEANED_COUNT worktree(s) - proceeding"
          WORKTREE_COUNT=$((WORKTREE_COUNT - CLEANED_COUNT))
        else
          # No clean worktrees found - look for oldest stale one
          print_info "No merged branches found - checking for stale worktrees..."

          OLDEST_WORKTREE=""
          OLDEST_AGE=0

          while IFS= read -r wt_path; do
            [ -z "$wt_path" ] && continue

            WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")
            [ -z "$WT_BRANCH" ] && continue

            # Check if has uncommitted changes
            UNCOMMITTED=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            [ "$UNCOMMITTED" -gt 0 ] && continue  # Skip if dirty

            # Get last modification time
            LAST_MODIFIED=$(find "$wt_path" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.sh" \) 2>/dev/null | xargs stat -f "%m" 2>/dev/null | sort -rn | head -1 || echo "0")
            AGE=$(( $(date +%s) - LAST_MODIFIED ))

            if [ "$AGE" -gt "$OLDEST_AGE" ]; then
              OLDEST_AGE=$AGE
              OLDEST_WORKTREE="$wt_path"
              OLDEST_BRANCH="$WT_BRANCH"
            fi
          done <<< "$EXISTING_WORKTREES"

          if [ -n "$OLDEST_WORKTREE" ] && [ "$OLDEST_AGE" -gt 86400 ]; then  # > 1 day old
            DAYS_OLD=$((OLDEST_AGE / 86400))
            print_info "Removing stale worktree: $OLDEST_BRANCH (${DAYS_OLD} days old, no uncommitted changes)"
            git worktree remove "$OLDEST_WORKTREE" 2>/dev/null || true
            git branch -d "$OLDEST_BRANCH" 2>/dev/null || true
            print_success "Removed stale worktree - will create new one for issue #$ISSUE_NUMBER"
          elif [ -n "$OLDEST_WORKTREE" ]; then
            # Has worktrees but all are recent (< 1 day) - still remove oldest if no uncommitted changes
            HOURS_OLD=$((OLDEST_AGE / 3600))
            print_warning "All worktrees are recent (oldest: ${HOURS_OLD}h)"
            print_info "Removing oldest clean worktree: $OLDEST_BRANCH"
            git worktree remove "$OLDEST_WORKTREE" 2>/dev/null || true
            git branch -d "$OLDEST_BRANCH" 2>/dev/null || true
            print_success "Removed worktree - will create new one for issue #$ISSUE_NUMBER"
          else
            # All worktrees have uncommitted changes - allow exceeding limit with warning
            print_warning "All worktrees have uncommitted changes"
            print_warning "Creating 4th worktree (exceeding limit of $MAX_WORKTREES)"
            echo ""
            print_info "Current worktrees (all have uncommitted work):"
            git worktree list | grep -v "main" | head -3
            echo ""
            print_info "Tip: Clean up later with: forge cleanup-worktrees"
          fi
        fi
      fi
    else
      print_success "No existing worktrees found"
    fi

    echo ""
    print_info "Creating worktree at: $WORKTREE_PATH"

    # Check if branch already exists
    if git show-ref --verify --quiet refs/heads/"$BRANCH_NAME"; then
      print_warning "Branch already exists"

      if [ "$AUTO_MODE" = false ]; then
        read -p "Create worktree for existing branch? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          print_error "Cancelled"
          exit 1
        fi
      else
        print_info "Using existing branch (auto mode)"
      fi

      # Try to add worktree - git will error if it already exists (handles TOCTOU race)
      if ! git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" 2>/dev/null; then
        # Worktree might have been created by another process (race condition)
        # Check if it exists now and use it
        if [ -d "$WORKTREE_PATH" ]; then
          print_info "Worktree was created by another process - using it"
        else
          print_error "Failed to create worktree"
          exit 1
        fi
      fi
    else
      # Create new branch in worktree - git handles race condition
      if ! git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" 2>/dev/null; then
        # Check if worktree exists (possible race condition)
        if [ -d "$WORKTREE_PATH" ]; then
          print_info "Worktree was created by another process - using it"
        else
          print_error "Failed to create worktree and branch"
          exit 1
        fi
      fi
    fi

    print_success "Worktree ready"

    # Symlink node_modules to save disk space (if project has them)
    if [ -d "$MAIN_WORKTREE/node_modules" ]; then
      print_info "Symlinking node_modules from main worktree..."
      cd "$WORKTREE_PATH"
      rm -rf node_modules 2>/dev/null || true
      ln -s "$MAIN_WORKTREE/node_modules" node_modules
      cd "$WORKTREE_PATH"
      print_success "node_modules symlinked"
    elif [ -d "$MAIN_WORKTREE/backend/node_modules" ]; then
      print_info "Symlinking backend/node_modules from main worktree..."
      cd "$WORKTREE_PATH/backend" 2>/dev/null || true
      rm -rf node_modules 2>/dev/null || true
      ln -s "$MAIN_WORKTREE/backend/node_modules" node_modules 2>/dev/null || true
      cd "$WORKTREE_PATH"
      print_success "node_modules symlinked"
    fi

    # Symlink forge data dir to share scratchpad and context across worktrees
    FORGE_DATA_PATH="$MAIN_WORKTREE/$FORGE_DATA_DIR"
    if [ -d "$FORGE_DATA_PATH" ]; then
      print_info "Symlinking $FORGE_DATA_DIR directory for shared scratchpad..."
      rm -rf "$WORKTREE_PATH/$FORGE_DATA_DIR" 2>/dev/null || true
      ln -s "$FORGE_DATA_PATH" "$WORKTREE_PATH/$FORGE_DATA_DIR"
      print_success "Shared scratchpad linked"
    fi

    # Also symlink .claude/ if it exists (backward compat)
    if [ -d "$MAIN_WORKTREE/.claude" ]; then
      rm -rf "$WORKTREE_PATH/.claude" 2>/dev/null || true
      ln -s "$MAIN_WORKTREE/.claude" "$WORKTREE_PATH/.claude"
    fi

    # Switch to worktree directory
    cd "$WORKTREE_PATH"
    print_success "Switched to worktree: $WORKTREE_PATH"

    # Store worktree path for cleanup later
    export CLAUDE_WORKTREE_PATH="$WORKTREE_PATH"

    # Check for relevant stashed changes and auto-apply if they're from this branch
    LATEST_STASH_BRANCH=$(git stash list 2>/dev/null | head -1 | grep -oE 'WIP on [^:]+|On [^:]+' | sed 's/.*On //' | sed 's/WIP on //' || echo "")

    if [ -n "$LATEST_STASH_BRANCH" ] && [ "$LATEST_STASH_BRANCH" = "$BRANCH_NAME" ]; then
      # Most recent stash is from this branch - auto-apply
      print_info "Found recent stash from this branch - auto-applying..."
      if git stash pop 2>/dev/null; then
        print_success "Stash applied"
      else
        print_warning "Could not apply stash (may have conflicts)"
        print_info "Resolve manually with: git stash pop"
      fi
    fi
fi

# Check git status
print_header "📊 Repository Status"
git status --short

# Count uncommitted changes (exclude untracked files and .gitignore)
# Only count modified (M), added (A), deleted (D), renamed (R), copied (C) files
# Exclude ?? (untracked) which includes symlinks
# Pattern: git status --porcelain shows " M file" for modified, "?? file" for untracked
UNCOMMITTED_CHANGES=$(git status --porcelain | { grep -vE "^\?\?" || true; } | { grep -v "\.gitignore$" || true; } | wc -l | tr -d ' ')
echo ""

if [ "$UNCOMMITTED_CHANGES" -gt 0 ]; then
  print_info "Found $UNCOMMITTED_CHANGES uncommitted changes"
  echo ""
  print_info "Work appears to be in progress - skipping Claude Code session"
  print_info "Will proceed directly to commit/PR workflow"
  echo ""

  # Set flag to skip Claude Code
  SKIP_CLAUDE=true
else
  print_success "No uncommitted changes (untracked files will be ignored)"
  SKIP_CLAUDE=false
fi

# PR-First Approach: Create draft PR early for tracking
# This allows us to find worktrees by PR instead of branch name patterns
print_header "📋 Creating Draft PR for Tracking"

# Check if PR already exists for this branch
EXISTING_PR=$(gh pr list --head "$BRANCH_NAME" --json number,title,url,isDraft --jq '.[0]' 2>/dev/null || echo "{}")

if [ "$EXISTING_PR" != "{}" ] && [ -n "$EXISTING_PR" ]; then
  PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number')
  PR_TITLE=$(echo "$EXISTING_PR" | jq -r '.title')
  IS_DRAFT=$(echo "$EXISTING_PR" | jq -r '.isDraft')

  # PR exists - no message needed (workflow-runner already informed user)
  echo ""
else
  # Create empty commit for PR (will be amended later with real changes)
  if ! git log --oneline -1 | grep -q "chore: initialize work"; then
    git commit --allow-empty -m "chore: initialize work on ${ISSUE_NUMBER:+#$ISSUE_NUMBER }${ISSUE_DESC}"
  fi

  # Push to create remote branch
  git push -u origin "$BRANCH_NAME" 2>/dev/null || true

  # Create draft PR
  PR_TITLE="$ISSUE_DESC"
  PR_BODY="## Work in Progress

$(if [ -n "$ISSUE_NUMBER" ]; then echo "Closes #$ISSUE_NUMBER"; fi)

This PR is being worked on. Implementation details will be updated as work progresses.

---
_Draft PR created automatically by forge for tracking purposes._"

  print_info "Creating draft PR..."

  gh pr create \
    --draft \
    --base main \
    --head "$BRANCH_NAME" \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    $(if [ -n "$ISSUE_NUMBER" ]; then echo "--label enhancement"; fi) \
    2>/dev/null || print_warning "PR creation failed (may already exist)"

  # Get PR number
  PR_NUMBER=$(gh pr list --head "$BRANCH_NAME" --json number --jq '.[0].number' 2>/dev/null)

  if [ -n "$PR_NUMBER" ]; then
    print_success "Draft PR #$PR_NUMBER created"
    echo ""
  else
    print_warning "Could not get PR number - continuing without PR link"
    echo ""
  fi
fi

# Build Claude Code prompt
print_header "🤖 Starting Claude Code Session"

# Show workflow summary
echo "📋 Workflow Summary:"
echo "   Issue: ${ISSUE_NUMBER:+#$ISSUE_NUMBER - }$ISSUE_DESC"
echo "   Branch: $BRANCH_NAME"
echo "   Location: $(pwd)"
echo ""

# Read scratchpad security findings if available
SECURITY_CONTEXT=""
# SCRATCHPAD_FILE set by config.sh

if [ -f "$SCRATCHPAD_FILE" ]; then
  print_info "Loading recent security findings from scratchpad..."

  # Extract "Recent Security Findings" section
  SECURITY_CONTEXT=$(sed -n '/## Recent Security Findings/,/## /p' "$SCRATCHPAD_FILE" | sed '1d;$d' || echo "")

  if [ -n "$SECURITY_CONTEXT" ]; then
    print_success "Loaded security context from last 5 PRs"
  fi

  # Update "Current Work" section
  TEMP_SCRATCH=$(mktemp)
  if grep -q "## Current Work" "$SCRATCHPAD_FILE"; then
    # Update existing section
    sed "/## Current Work/,/^## /{//!d;}" "$SCRATCHPAD_FILE" > "$TEMP_SCRATCH"
    sed -i '' "/## Current Work/a\\
\\
**Issue:** #${ISSUE_NUMBER:-unknown}\\
**Description:** ${ISSUE_DESC}\\
**Branch:** ${BRANCH_NAME:-$CURRENT_BRANCH}\\
**Started:** $(date '+%Y-%m-%d %H:%M:%S')\\
" "$TEMP_SCRATCH"
    mv "$TEMP_SCRATCH" "$SCRATCHPAD_FILE"
  else
    # Add section if missing
    echo -e "\n## Current Work\n\n**Issue:** #${ISSUE_NUMBER:-unknown}\n**Description:** ${ISSUE_DESC}\n**Branch:** ${BRANCH_NAME:-$CURRENT_BRANCH}\n**Started:** $(date '+%Y-%m-%d %H:%M:%S')\n" >> "$SCRATCHPAD_FILE"
  fi
fi

SECURITY_PROMPT=""
if [ -n "$SECURITY_CONTEXT" ]; then
  SECURITY_PROMPT="

## ⚠️ Recent Security Findings (Last 5 PRs)

**IMPORTANT:** Review these security issues found in recent PRs. Avoid repeating these patterns:

$SECURITY_CONTEXT

---
"
fi

if [ "$AUTO_MODE" = true ]; then
  PHASE_0_INSTRUCTIONS="**AUTO MODE: Make reasonable assumptions and proceed without stopping for clarification.**

1. Review the task description: \"${ISSUE_DESC}\"
2. Make sensible defaults based on:
   - Existing patterns in the codebase
   - Industry best practices (e.g., OWASP recommendations for security)
   - Standard configurations for the technology stack
3. **Skip clarification questions and proceed directly to Phase 1**
4. Document your assumptions in the implementation"
else
  PHASE_0_INSTRUCTIONS="1. Review the task description: \"${ISSUE_DESC}\"
2. Determine if clarification is needed based on:
   - Is the scope clear?
   - Does this follow existing patterns in the codebase?
   - Are there ambiguous requirements?
3. **Skip this phase** for straightforward tasks like:
   - Simple bug fixes (\"fix typo in README\")
   - Clear updates (\"add logging to auth-service\")
   - Configuration changes (\"update test timeout to 30s\")
4. **Ask focused questions** for complex/ambiguous tasks:
   - \"add OAuth integration\" → Which provider? Which flows?
   - \"improve rate limiting\" → What's the problem? New limits?
   - \"add health check endpoint\" → What should it check? Auth required?
5. Wait for answers before proceeding to Phase 1"
fi


# Set auto mode instructions
if [ "$AUTO_MODE" = true ]; then
  AUTO_MODE_INSTRUCTION="Proceed directly to implementation (auto mode - no approval needed)"
  AUTO_MODE_FINAL_NOTE="**Auto Mode**: Complete all phases automatically. After Phase 5:
1. Provide a brief summary of what you implemented
2. **IMPORTANT: Exit Claude Code immediately** by typing \`/quit\` or \`/exit\`
3. The post-workflow script will automatically handle commit, push, and PR creation

**You must exit after completing Phase 5 for the automation to continue!**"
else
  AUTO_MODE_INSTRUCTION="Wait for my approval before implementing"
  AUTO_MODE_FINAL_NOTE="After Phase 4, I'll review and we'll commit together."
fi

CLAUDE_PROMPT="Task: ${ISSUE_DESC}
${SECURITY_PROMPT}
## Workflow Instructions

**IMPORTANT: Use the TodoWrite tool to track progress throughout this workflow.**

Before starting, create a todo list with these items:
1. Phase 0: Requirements Clarification - Ask questions if task is ambiguous
2. Phase 1: Analysis - Understanding the codebase and requirements
3. Phase 2: Planning - Designing the implementation approach
4. Phase 3: Implementation - Writing the code
5. Phase 4: Testing & Validation - Running tests and verifying correctness
6. Phase 5: Documentation - Updating docs and comments

Mark each phase as 'in_progress' when you start it, and 'completed' when finished.
For complex phases, break them into sub-tasks.

Please follow this structured workflow:

### Phase 0: Requirements Clarification
${PHASE_0_INSTRUCTIONS}

### Phase 1: Analysis
1. **FIRST: Check if work is already complete** - Search codebase to verify if acceptance criteria are already met
2. If work is complete:
   - Report your findings with evidence (file paths, test results, etc.)
   - Check if a PR exists for this issue (use: gh pr list --search \"<issue-title>\" --state all)
   - **If PR exists on different branch:**
     - Inform user: Work already merged/in-review on another branch
     - Close this branch and worktree (duplicate work)
     - Close the issue if PR is merged
     - **STOP - cleanup complete**
   - **If no PR exists:**
     - Inform user: Work is complete but not in a PR yet
     - Skip to Phase 4 (Testing) to verify everything works
     - Then continue to PR creation and full workflow
     - **DO NOT skip the workflow - this branch has the completed work**
3. If work is incomplete, continue with analysis:
   - Read relevant files to understand the codebase
   - Search for related patterns and existing implementations
   - Review project documentation (CLAUDE.md, docs/Technical-Specs.md)
   - **CRITICAL: For security-sensitive code**, consult docs/security/DEVELOPMENT-GUIDE.md
   - Identify dependencies and integration points

### Phase 2: Planning
1. Explain your proposed implementation approach
2. List all files you'll create or modify
3. Identify potential issues or trade-offs
4. ${AUTO_MODE_INSTRUCTION}

### Phase 3: Implementation
1. Implement the solution following best practices
2. Follow existing code patterns and conventions
3. Add proper error handling
4. Include comments for complex logic
5. Ensure multi-tenant isolation if applicable

### Phase 4: Testing & Validation
1. Write or update unit tests
2. Run existing tests: npm test
3. Verify code builds: npm run build
4. Check for linting issues

### Phase 5: Documentation
1. Update relevant documentation
2. Add comments to complex code
3. Update CHANGELOG if applicable

**Remember**: Update your todo list as you complete each phase. Mark the current phase as 'in_progress' and completed phases as 'completed'.

${AUTO_MODE_FINAL_NOTE}

Ready to start? Begin with Phase 0: Requirements Clarification."

echo "Starting Claude Code with task:"
echo "\"$ISSUE_DESC\""
echo ""

# Detect if already running in Claude Code
ALREADY_IN_CLAUDE=false
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_SESSION:-}" ] || ps aux | grep -v grep | grep -q "claude-code"; then
  ALREADY_IN_CLAUDE=true
fi

# Run Claude Code (unless skipped)
if [ "$SKIP_CLAUDE" = true ]; then
  print_info "Skipping Claude Code session (work already in progress)"
  print_info "Proceeding to post-workflow"
  echo ""
elif [ "$ALREADY_IN_CLAUDE" = true ]; then
  print_warning "Already running inside Claude Code - skipping recursive invocation"
  print_info "Claude Code work complete - proceeding to post-workflow"
  echo ""
else
  # Set timeout for Claude Code (configurable via FORGE_CLAUDE_TIMEOUT, default 2 hours)
  CLAUDE_TIMEOUT=${FORGE_CLAUDE_TIMEOUT:-7200}
  print_info "Launching Claude Code (timeout: ${CLAUDE_TIMEOUT}s)..."

  if [ "$AUTO_MODE" = true ]; then
    timeout "${CLAUDE_TIMEOUT}" $CLAUDE_CMD --permission-mode bypassPermissions "$CLAUDE_PROMPT" &
    CLAUDE_PID=$!
  else
    timeout "${CLAUDE_TIMEOUT}" $CLAUDE_CMD "$CLAUDE_PROMPT" &
    CLAUDE_PID=$!
  fi

  # In auto mode, show periodic heartbeat while waiting
  if [ "$AUTO_MODE" = true ]; then
    (
      elapsed=0
      while kill -0 $CLAUDE_PID 2>/dev/null; do
        sleep 60
        elapsed=$((elapsed + 60))
        echo "⏱️  Claude Code running... (${elapsed}s elapsed)"
      done
    ) &
    HEARTBEAT_PID=$!
  fi

  # Wait for Claude Code to complete
  CLAUDE_EXIT_CODE=0
  wait $CLAUDE_PID || CLAUDE_EXIT_CODE=$?

  # Stop heartbeat if running
  if [ -n "${HEARTBEAT_PID:-}" ]; then
    kill $HEARTBEAT_PID 2>/dev/null || true
    wait $HEARTBEAT_PID 2>/dev/null || true
  fi

  # Handle timeout (exit code 124 from timeout command)
  if [ $CLAUDE_EXIT_CODE -eq 124 ]; then
    print_error "Claude Code timed out after ${CLAUDE_TIMEOUT}s"
    print_info "Checking for uncommitted work..."

    if [ "$(git status --porcelain | wc -l | tr -d ' ')" -gt 0 ]; then
      print_warning "Found uncommitted changes - committing before exit"
      # Fall through to post-workflow to commit changes
    else
      print_error "No changes detected - workflow failed"
      exit 1
    fi
  elif [ $CLAUDE_EXIT_CODE -ne 0 ]; then
    print_error "Claude Code exited with error code $CLAUDE_EXIT_CODE"
    print_info "Checking for uncommitted work..."

    if [ "$(git status --porcelain | wc -l | tr -d ' ')" -gt 0 ]; then
      print_warning "Found uncommitted changes - will attempt to save work"
      # Fall through to post-workflow to commit changes
    else
      exit 1
    fi
  fi
fi

# Post-Claude workflow
if [ "${SKIP_TO_PR:-false}" = true ]; then
  # PR already exists, skip commit/push and go straight to PR workflow
  echo ""
else
  if [ "$AUTO_MODE" = false ]; then
    print_header "📝 Post-Implementation Workflow"
    echo "Claude Code session complete. Let's review what changed."
    echo ""
  fi

  # Show changes
  if [ "$AUTO_MODE" = false ]; then
    git status --short
  fi
  CHANGES_COUNT=$(git status --porcelain | wc -l)

if [ $CHANGES_COUNT -eq 0 ]; then
  print_info "No new changes detected"
  echo ""
  print_info "Checking if PR workflow is needed (branch may have existing commits)..."

  # Skip to PR workflow - there may be existing commits that need PR/review
  # Even without new changes, we should check for PR, review feedback, etc.
else
  print_success "$CHANGES_COUNT file(s) changed"
  echo ""

  # Show diff stats
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  git diff --stat
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Run tests
if [ "$AUTO_MODE" = false ]; then
  read -p "🧪 Run tests before committing? (y/n) " -n 1 -r
  echo
  RUN_TESTS=$REPLY
else
  # Auto mode: skip tests (will be run in CI)
  print_info "Skipping tests (will run in CI)"
  RUN_TESTS="n"
fi

if [[ $RUN_TESTS =~ ^[Yy]$ ]]; then
  print_info "Running tests..."

  if [ -f "package.json" ]; then
    if npm test 2>&1; then
      print_success "All tests passed"
    else
      print_warning "Some tests failed"

      if [ "$AUTO_MODE" = false ]; then
        echo ""
        read -p "Continue with commit anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          print_info "Fix tests and run again"
          exit 1
        fi
      else
        print_warning "Continuing anyway (auto mode)"
      fi
    fi
  elif [ -f "backend/package.json" ]; then
    cd backend
    if npm test 2>&1; then
      print_success "All tests passed"
    else
      print_warning "Some tests failed"

      if [ "$AUTO_MODE" = false ]; then
        echo ""
        read -p "Continue with commit anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          print_info "Fix tests and run again"
          exit 1
        fi
      else
        print_warning "Continuing anyway (auto mode)"
      fi
    fi
    cd ..
  else
    print_warning "No package.json found, skipping tests"
  fi
fi

# Commit workflow
if [ "$AUTO_MODE" = false ]; then
  echo ""
  read -p "📝 Create commit? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Skipped commit. Run forge --continue to resume."
    exit 0
  fi
fi

# Smart commit message generation
if [ "$AUTO_MODE" = false ]; then
  print_info "Generating commit message..."
fi

# Extract commit type from branch name
COMMIT_TYPE="feat"
if [[ "$BRANCH_NAME" =~ ^(fix|feat|docs|test|refactor|chore)/ ]]; then
  COMMIT_TYPE=$(echo "$BRANCH_NAME" | cut -d'/' -f1)
fi

# Generate commit subject from branch name
COMMIT_SUBJECT=$(echo "$BRANCH_NAME" | sed 's/.*\///' | tr '-' ' ')

# Conventional commit message
COMMIT_MSG="${COMMIT_TYPE}: ${COMMIT_SUBJECT}"

if [ "$AUTO_MODE" = false ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Suggested commit message:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$COMMIT_MSG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -p "Accept this message? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Enter custom commit message:"
    read -e CUSTOM_MSG
    COMMIT_MSG="$CUSTOM_MSG"
  fi
elif [ "$AUTO_MODE" = false ]; then
  print_info "Using auto-generated commit message: $COMMIT_MSG"
fi

# Create commit (use -A to respect .gitignore)
git add -A

# CRITICAL: Remove worktree-specific symlinks from staging
# These symlinks are created by the workflow but should NEVER be committed
if git ls-files --stage | grep -q '^120000.*\.claude$'; then
  git reset HEAD .claude 2>/dev/null || true
  print_warning "Removed .claude symlink from staging (worktree-specific)"
fi

if git ls-files --stage | grep -q "^120000.*${FORGE_DATA_DIR}$"; then
  git reset HEAD "$FORGE_DATA_DIR" 2>/dev/null || true
  print_warning "Removed $FORGE_DATA_DIR symlink from staging (worktree-specific)"
fi

if git ls-files --stage | grep -q '^120000.*backend/node_modules$'; then
  git reset HEAD backend/node_modules 2>/dev/null || true
  print_warning "Removed backend/node_modules symlink from staging (worktree-specific)"
fi

if git ls-files --stage | grep -q '^120000.*node_modules$'; then
  git reset HEAD node_modules 2>/dev/null || true
  print_warning "Removed node_modules symlink from staging (worktree-specific)"
fi

git commit -m "$COMMIT_MSG" > /dev/null

if [ "$AUTO_MODE" = true ]; then
  echo "✅ Committed: $COMMIT_MSG"
else
  print_success "Commit created"
  echo ""
fi

# Push workflow
if [ "$AUTO_MODE" = false ]; then
  read -p "🚀 Push to remote? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Changes committed locally. Push later with:"
    echo "  git push -u origin $BRANCH_NAME"
    exit 0
  fi
else
  echo "🚀 Pushing to remote..."
fi

# Push with upstream tracking
if [ "$AUTO_MODE" = true ]; then
  git push -u origin "$BRANCH_NAME" 2>&1 | grep -E "(Writing objects|remote:)" || true
  echo "✅ Pushed to origin/$BRANCH_NAME"
else
  git push -u origin "$BRANCH_NAME"
  print_success "Pushed to origin/$BRANCH_NAME"
  echo ""
fi
fi  # End of "if CHANGES_COUNT > 0" block
fi  # End of "if SKIP_TO_PR" block

# PR workflow - automatically handled by create-pr.sh
# This runs whether or not there were new changes (existing commits may need PR)
if [ "$AUTO_MODE" = false ]; then
  print_header "🔗 Pull Request & Review Workflow"
fi

if [ -f "$FORGE_LIB_DIR/core/create-pr.sh" ]; then
  # create-pr.sh handles everything:
  # - Detects if PR exists for current branch
  # - Creates PR if needed
  # - Waits for automated review (dynamic wait time)
  # - Assesses review issues and determines action
  # - Provides merge recommendation
  if [ "$AUTO_MODE" = true ]; then
    "$FORGE_LIB_DIR/core/create-pr.sh" --auto
  else
    "$FORGE_LIB_DIR/core/create-pr.sh"
  fi
else
  # Fallback if create-pr.sh not found
  print_warning "create-pr.sh not found, skipping PR workflow"
  print_info "Manually create PR with: gh pr create"
fi

# Summary
print_header "🎉 Workflow Complete"

echo "Summary:"
echo "  Branch: $BRANCH_NAME"
echo "  Commits: $(git rev-list --count origin/main..HEAD 2>/dev/null || echo "1")"
echo "  Changes: $CHANGES_COUNT files"
echo ""

# Check if PR was created
PR_JSON=$(gh pr list --head "$BRANCH_NAME" --json number,title,url --jq '.[0]' 2>/dev/null || echo "")

if [ ! -z "$PR_JSON" ] && [ "$PR_JSON" != "null" ]; then
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
  PR_URL=$(echo "$PR_JSON" | jq -r '.url')

  echo "Next steps:"
  echo "  1. Review PR: $PR_URL"
  echo "  2. Wait for automated review (handled by create-pr.sh)"
  echo "  3. Address feedback if any (assess-and-resolve.sh)"
  echo "  4. Merge when approved"

  if [ -n "$WORKTREE_PATH" ]; then
    echo ""
    print_info "Worktree will be cleaned up after merge"
    echo "  Location: $WORKTREE_PATH"
  fi
else
  echo "Next steps:"
  echo "  1. PR creation handled by create-pr.sh"
  echo "  2. Automated review will follow"
  echo "  3. Merge when approved"
fi

# Check if still in worktree
CURRENT_PATH=$(pwd)
if [[ "$CURRENT_PATH" == *"$(basename "$FORGE_WORKTREE_DIR")"* ]] || [ -n "$WORKTREE_PATH" ]; then
  echo ""
  print_info "You are in an isolated worktree"
  echo "  Location: ${WORKTREE_PATH:-$CURRENT_PATH}"
  echo "  Changes here won't affect other terminals or main worktree"
  echo "  Worktree will be cleaned up after PR merge"
fi

# Post-workflow cleanup: Exit worktree and return to main repo
CURRENT_PATH=$(pwd)
MAIN_REPO=$(git worktree list | head -1 | awk '{print $1}')

if [ -n "$MAIN_REPO" ] && [ "$CURRENT_PATH" != "$MAIN_REPO" ]; then
  echo ""
  print_info "Workflow complete - returning to main repository"
  cd "$MAIN_REPO" || cd "$HOME"
  print_success "Exited worktree: $CURRENT_PATH"
  print_info "To return to worktree: cd $CURRENT_PATH"
fi

echo ""
print_success "All done!"
