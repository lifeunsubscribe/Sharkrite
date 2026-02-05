#!/bin/bash
# scripts/create-pr.sh
# Intelligent PR creation with automated review waiting and comprehensive assessment
# Usage:
#   ./scripts/create-pr.sh <issue-number>  # Create PR from issue
#   ./scripts/create-pr.sh                 # Create/check PR from current branch
#   ./scripts/create-pr.sh --auto          # Automated mode (no prompts)

set -euo pipefail

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../utils/config.sh"
fi

# Source blocker rules for early detection
source "$RITE_LIB_DIR/utils/blocker-rules.sh"

# Parse arguments
AUTO_MODE=false
ISSUE_NUMBER=""
BASE_BRANCH="main"

while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --base)
      BASE_BRANCH="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_NUMBER="$1"
      fi
      shift
      ;;
  esac
done

CURRENT_BRANCH=$(git branch --show-current)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  print_error "jq required: brew install jq"
  exit 1
fi

# Smart navigation: if on main/develop and issue number provided, find worktree
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "develop" ]]; then
  if [ ! -z "$ISSUE_NUMBER" ]; then
    print_info "On $CURRENT_BRANCH branch - looking for worktree for issue #$ISSUE_NUMBER..."

    # Find worktree with this issue number
    TARGET_WORKTREE=$(git worktree list --porcelain | grep -E "^worktree $RITE_WORKTREE_DIR" | sed 's/^worktree //' | while read -r wt_path; do
      wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")
      if echo "$wt_branch" | grep -qE "issue-?$ISSUE_NUMBER"; then
        echo "$wt_path"
        break
      fi
    done)

    if [ -n "$TARGET_WORKTREE" ]; then
      print_success "Found worktree for issue #$ISSUE_NUMBER"
      print_info "Auto-navigating to: $TARGET_WORKTREE"

      cd "$TARGET_WORKTREE"
      exec "$0" "$ISSUE_NUMBER"  # Re-run script in correct worktree
      exit 0
    else
      print_error "No worktree found for issue #$ISSUE_NUMBER"
      print_info "First run: forge $ISSUE_NUMBER --quick"
      exit 1
    fi
  else
    print_error "Cannot create PR from $CURRENT_BRANCH branch"
    print_info "Either:"
    print_info "  1. Switch to feature branch: git checkout BRANCH_NAME"
    print_info "  2. Provide issue number: $0 ISSUE_NUMBER"
    exit 1
  fi
fi

if [ "$AUTO_MODE" = false ]; then
  print_header "🔍 Checking for Existing PR"
fi

# Check if PR already exists for this branch
EXISTING_PR=$(gh pr list --head "$CURRENT_BRANCH" --json number,title,url,state,isDraft --jq '.[0]' 2>/dev/null || echo "")

PR_EXISTS=false
if [ ! -z "$EXISTING_PR" ] && [ "$EXISTING_PR" != "null" ]; then
  PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number')
  PR_URL=$(echo "$EXISTING_PR" | jq -r '.url')
  PR_TITLE=$(echo "$EXISTING_PR" | jq -r '.title')
  PR_STATE=$(echo "$EXISTING_PR" | jq -r '.state')
  IS_DRAFT=$(echo "$EXISTING_PR" | jq -r '.isDraft')

  print_info "PR already exists for branch '$CURRENT_BRANCH'"
  echo "  PR #$PR_NUMBER: $PR_TITLE"
  echo "  State: $PR_STATE"
  echo "  Draft: $IS_DRAFT"
  echo "  URL: $PR_URL"
  echo ""

  if [ "$PR_STATE" != "OPEN" ]; then
    print_warning "PR is $PR_STATE - cannot process"
    exit 0
  fi

  PR_EXISTS=true

  # If PR is draft, mark it as ready for review (work is complete)
  if [ "$IS_DRAFT" = "true" ]; then
    print_info "PR is draft - marking as ready for review..."
    gh pr ready "$PR_NUMBER" 2>/dev/null || print_warning "Could not mark PR as ready"
    print_success "PR marked as ready for review"
    echo ""
  fi

  # Check if there are new commits since PR was last updated
  CURRENT_HEAD=$(git rev-parse HEAD)
  PR_HEAD=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')

  if [ "$CURRENT_HEAD" != "$PR_HEAD" ]; then
    # Push new commits to PR first
    print_info "Pushing new commits to PR..."
    git push origin "$CURRENT_BRANCH" 2>&1 | grep -v "To github.com" || true

    # Update PR description with latest changes
    print_info "Updating PR description..."
    UPDATED_BODY="## Recent Changes

$(git log --oneline origin/$BASE_BRANCH..HEAD 2>/dev/null | head -10)

## Latest Commit

$(git log -1 --pretty=format:%B)

---

_Updated: $(date +%Y-%m-%d\ %H:%M:%S)_"

    gh pr edit "$PR_NUMBER" --body "$UPDATED_BODY" 2>/dev/null || print_warning "Could not update PR description"
    print_success "PR updated with new commits"
    echo ""
  else
    print_info "No new commits since last push"
    echo ""
  fi
fi

# If PR doesn't exist, create it
if [ "$PR_EXISTS" = false ]; then
  if [ "$AUTO_MODE" = false ]; then
    print_header "📝 Creating New Pull Request"
  fi

  # If issue number provided, fetch issue details
  if [ ! -z "$ISSUE_NUMBER" ]; then
    print_info "Fetching issue #$ISSUE_NUMBER details..."

    ISSUE_JSON=$(gh issue view $ISSUE_NUMBER --json title,body,labels 2>/dev/null || echo "")

    if [ ! -z "$ISSUE_JSON" ]; then
      ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
      ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body')
      ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

      print_success "Issue: $ISSUE_TITLE"
    fi
  fi

  # Generate PR title
  if [ ! -z "$ISSUE_NUMBER" ] && [ ! -z "$ISSUE_TITLE" ]; then
    PR_TITLE="$ISSUE_TITLE"
  else
    # Extract title from branch name
    PR_TITLE=$(echo "$CURRENT_BRANCH" | sed 's/.*\///' | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
  fi

  # Get commit summary
  COMMIT_SUMMARY=$(git log --oneline origin/$BASE_BRANCH..HEAD 2>/dev/null || git log --oneline HEAD~5..HEAD)
  COMMIT_COUNT=$(echo "$COMMIT_SUMMARY" | wc -l | tr -d ' ')

  # Get file changes summary
  FILES_CHANGED=$(git diff --name-status origin/$BASE_BRANCH..HEAD 2>/dev/null || git diff --name-status HEAD~1..HEAD)
  FILES_ADDED=$(echo "$FILES_CHANGED" | grep -c '^A' || echo "0")
  FILES_MODIFIED=$(echo "$FILES_CHANGED" | grep -c '^M' || echo "0")
  FILES_DELETED=$(echo "$FILES_CHANGED" | grep -c '^D' || echo "0")

  # Build PR body
  PR_BODY=$(cat <<EOF
## Summary

$(if [ ! -z "$ISSUE_NUMBER" ]; then echo "Closes #${ISSUE_NUMBER}"; fi)

${ISSUE_TITLE:-"Changes to ${CURRENT_BRANCH}"}

## Changes Made

**Commits:** $COMMIT_COUNT
**Files Changed:** +$FILES_ADDED ~$FILES_MODIFIED -$FILES_DELETED

### Commit History
$(echo "$COMMIT_SUMMARY" | sed 's/^/- /')

## Testing

- [x] Code builds successfully
- [x] Unit tests pass locally
- [ ] Integration tests pass (CI will verify)
- [ ] Claude Code review pending

## Security Checklist

- [ ] Multi-tenant isolation verified (if applicable)
- [ ] Input validation present
- [ ] No secrets in code
- [ ] Error handling comprehensive

## Review Notes

**Branch:** \`$CURRENT_BRANCH\`
**Base:** \`$BASE_BRANCH\`
**Created:** $(date +%Y-%m-%d\ %H:%M:%S)
EOF
)

  # Determine labels
  if [ ! -z "${ISSUE_LABELS:-}" ]; then
    LABELS="$ISSUE_LABELS"
  else
    # Smart label detection from branch name
    LABELS=""
    if [[ "$CURRENT_BRANCH" == *"fix"* ]] || [[ "$CURRENT_BRANCH" == *"bug"* ]]; then
      LABELS="bug"
    elif [[ "$CURRENT_BRANCH" == *"feat"* ]] || [[ "$CURRENT_BRANCH" == *"feature"* ]]; then
      LABELS="enhancement"
    elif [[ "$CURRENT_BRANCH" == *"docs"* ]]; then
      LABELS="documentation"
    fi
  fi

  # Build PR creation args
  PR_ARGS=(
    --base "$BASE_BRANCH"
    --head "$CURRENT_BRANCH"
    --title "$PR_TITLE"
    --body "$PR_BODY"
  )

  # Add labels if available
  if [ ! -z "$LABELS" ]; then
    PR_ARGS+=(--label "$LABELS")
  fi

  # Create the PR
  PR_URL=$(gh pr create "${PR_ARGS[@]}")

  if [ $? -eq 0 ]; then
    # Extract PR number from URL
    PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

    print_success "Pull Request Created"
    echo "  PR #$PR_NUMBER"
    echo "  URL: $PR_URL"
    echo ""

    # Add comment to issue if applicable
    if [ ! -z "$ISSUE_NUMBER" ]; then
      gh issue comment "$ISSUE_NUMBER" --body "🔗 Pull Request created: $PR_URL

Automated review in progress..." 2>/dev/null || true
    fi
  else
    print_error "Failed to create PR"
    exit 1
  fi
fi

# Early blocker detection: Check for file-based blockers BEFORE waiting for review
# This prevents wasting time waiting for a review that will be blocked anyway
print_info "Running pre-review blocker checks..."

# Check for various file-based blockers
blocker_detected=false
blocker_type=""
blocker_details=""

if ! detect_infrastructure_changes "$PR_NUMBER" 2>&1 >/dev/null; then
  blocker_type="infrastructure"
  blocker_details=$(detect_infrastructure_changes "$PR_NUMBER" 2>&1)
  blocker_detected=true
elif ! detect_database_migrations "$PR_NUMBER" 2>&1 >/dev/null; then
  blocker_type="database_migration"
  blocker_details=$(detect_database_migrations "$PR_NUMBER" 2>&1)
  blocker_detected=true
elif ! detect_auth_changes "$PR_NUMBER" 2>&1 >/dev/null; then
  blocker_type="auth_changes"
  blocker_details=$(detect_auth_changes "$PR_NUMBER" 2>&1)
  blocker_detected=true
elif ! detect_doc_changes "$PR_NUMBER" 2>&1 >/dev/null; then
  blocker_type="architectural_docs"
  blocker_details=$(detect_doc_changes "$PR_NUMBER" 2>&1)
  blocker_detected=true
elif ! detect_expensive_services "$PR_NUMBER" 2>&1 >/dev/null; then
  blocker_type="expensive_services"
  blocker_details=$(detect_expensive_services "$PR_NUMBER" 2>&1)
  blocker_detected=true
elif ! detect_protected_scripts "$PR_NUMBER" 2>&1 >/dev/null; then
  blocker_type="protected_scripts"
  blocker_details=$(detect_protected_scripts "$PR_NUMBER" 2>&1)
  blocker_detected=true
fi

if [ "$blocker_detected" = true ]; then
  print_warning "Blocker detected: $blocker_type"
  echo ""
  echo "$blocker_details"
  echo ""
  print_info "This PR requires manual review before proceeding"
  print_info "Run in supervised mode to review and approve: forge <issue> --supervised"
  echo ""

  # Export blocker details for workflow-runner to handle
  export BLOCKER_TYPE="$blocker_type"
  export BLOCKER_DETAILS="$blocker_details"
  exit 10  # Exit code 10 signals blocker detected
fi

print_success "No file-based blockers detected"
echo ""

# Check if an automated reviewer is likely installed on this repo
# Look for recent comments from known review bots on any PR
REVIEW_BOT_DETECTED=false
RECENT_BOT_COMMENT=$(gh api "repos/{owner}/{repo}/issues/comments?per_page=30&sort=created&direction=desc" \
  --jq '[.[] | select(.user.login == "claude[bot]" or .user.login == "claude" or .user.login == "github-actions[bot]" and (.body | test("review|CRITICAL|WARNING|MINOR"; "i")))] | length' \
  2>/dev/null || echo "0")

if [ "${RECENT_BOT_COMMENT:-0}" -gt 0 ]; then
  REVIEW_BOT_DETECTED=true
fi

if [ "$REVIEW_BOT_DETECTED" = false ]; then
  print_warning "No automated review bot detected on this repo"
  echo ""
  echo "  Forge looks for review comments from: claude[bot], github-actions[bot]"
  echo "  To enable automated reviews, install the Claude for GitHub app:"
  echo "  https://github.com/apps/claude"
  echo ""
  print_info "Skipping review wait — PR is ready for manual review"
  echo "  PR: ${PR_URL:-#$PR_NUMBER}"
  echo ""
  exit 0
fi

# Set up SIGINT trap for clean Ctrl-C exit during review wait
trap 'echo ""; print_warning "Review wait interrupted by user (Ctrl-C)"; exit 130' SIGINT

# Now wait for automated review
if [ "$AUTO_MODE" = false ]; then
  print_header "⏳ Waiting for Automated Claude Code Review"
fi

# Dynamic wait time based on PR complexity
# Base: 90s + additional time based on:
# - Files changed (5s per file, max 60s)
# - Lines changed (0.1s per line, max 60s)
FILES_COUNT=$(git diff --numstat origin/$BASE_BRANCH..HEAD 2>/dev/null | wc -l | tr -d ' ')
LINES_CHANGED=$(git diff --stat origin/$BASE_BRANCH..HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || echo "100")

# Calculate dynamic wait
BASE_WAIT=90
FILE_WAIT=$((FILES_COUNT * 5))
[ "$FILE_WAIT" -gt 60 ] && FILE_WAIT=60

LINE_WAIT=$((LINES_CHANGED / 10))
[ "$LINE_WAIT" -gt 60 ] && LINE_WAIT=60

INITIAL_WAIT=$((BASE_WAIT + FILE_WAIT + LINE_WAIT))

print_info "Dynamic wait time: ${INITIAL_WAIT}s (base: ${BASE_WAIT}s + files: ${FILE_WAIT}s + complexity: ${LINE_WAIT}s)"
print_info "PR size: $FILES_COUNT files, ~$LINES_CHANGED lines changed"
echo ""

# Initialize PR_READY flag
PR_READY=false

# Check if review already exists before waiting
LATEST_COMMIT_TIME=$(gh pr view $PR_NUMBER --json commits \
  --jq '.commits[-1].committedDate' 2>/dev/null)

EXISTING_REVIEW_DATA=$(gh pr view $PR_NUMBER --json comments \
  --jq '[.comments[] | select(.author.login == "claude" or .author.login == "claude[bot]" or .author.login == "github-actions[bot]")] | .[-1] | {body: .body, createdAt: .createdAt}' \
  2>/dev/null)

EXISTING_REVIEW_TIME=$(echo "$EXISTING_REVIEW_DATA" | jq -r '.createdAt' 2>/dev/null)

# Check if review was created after latest commit
if [ -n "$EXISTING_REVIEW_TIME" ] && [ "$EXISTING_REVIEW_TIME" != "null" ] && \
   [ -n "$LATEST_COMMIT_TIME" ] && [ "$LATEST_COMMIT_TIME" != "null" ]; then
  # Compare timestamps
  if [[ "$EXISTING_REVIEW_TIME" > "$LATEST_COMMIT_TIME" ]] || [[ "$EXISTING_REVIEW_TIME" == "$LATEST_COMMIT_TIME" ]]; then
    print_success "Review found! (created after latest commit)"
    PR_READY=true
  fi
fi

# Only wait if no review exists yet
if [ "$PR_READY" != true ]; then
  print_info "Waiting for Claude Code review comment on PR #$PR_NUMBER..."
  echo "  Checking for comments from: claude, claude-code, github-actions[bot]"
  echo "  Looking for: comment posted AFTER latest commit"
  echo ""

  # Live countdown timer (only show if terminal is interactive)
  if [ -t 1 ]; then
    # Interactive terminal - show live countdown
    REMAINING=$INITIAL_WAIT
    while [ $REMAINING -gt 0 ]; do
      printf "\r⏳ Waiting: %ds remaining (will check every 15s after initial wait)..." "$REMAINING"
      sleep 1
      REMAINING=$((REMAINING - 1))
    done
    printf "\r✓ Initial wait complete (${INITIAL_WAIT}s)                                     \n"
  else
    # Non-interactive (piped) - just sleep without countdown
    sleep "$INITIAL_WAIT"
    echo "✓ Initial wait complete (${INITIAL_WAIT}s)"
  fi
fi

# Check for review every 15 seconds for up to 2 more minutes if needed
MAX_ADDITIONAL_WAIT=120
ELAPSED=$INITIAL_WAIT
CHECK_INTERVAL=15

# PR_READY tracks whether PR is ready to proceed to next phase:
#   - true = fresh review found OR old review issues resolved -> proceed to assess-and-resolve
#   - false = no review yet OR old review with unresolved issues -> keep waiting

MAX_TOTAL_WAIT=$((INITIAL_WAIT + MAX_ADDITIONAL_WAIT))

# Wait for PR to be ready (either fresh review or old issues resolved)
while [ "$PR_READY" != true ] && [ $ELAPSED -lt $MAX_TOTAL_WAIT ]; do
  # Get latest commit timestamp and review timestamp to ensure review is fresh
  LATEST_COMMIT_TIME=$(gh pr view $PR_NUMBER --json commits \
    --jq '.commits[-1].committedDate' 2>/dev/null)

  # Check for Claude Code review comments with timestamp
  REVIEW_DATA=$(gh pr view $PR_NUMBER --json comments \
    --jq '[.comments[] | select(.author.login == "claude" or .author.login == "claude-code" or .author.login == "github-actions[bot]")] | .[-1] | {body: .body, createdAt: .createdAt, author: .author.login}' \
    2>/dev/null)

  LATEST_REVIEW=$(echo "$REVIEW_DATA" | jq -r '.body' 2>/dev/null)
  REVIEW_TIME=$(echo "$REVIEW_DATA" | jq -r '.createdAt' 2>/dev/null)
  REVIEW_AUTHOR=$(echo "$REVIEW_DATA" | jq -r '.author' 2>/dev/null)

  if [ -n "$LATEST_REVIEW" ] && [ "$LATEST_REVIEW" != "null" ]; then
    # Verify review is newer than latest commit
    if [ -n "$REVIEW_TIME" ] && [ -n "$LATEST_COMMIT_TIME" ]; then
      if [[ "$REVIEW_TIME" > "$LATEST_COMMIT_TIME" ]]; then
        print_success "Review found from @$REVIEW_AUTHOR!"
        echo "  Latest commit: $LATEST_COMMIT_TIME"
        echo "  Review posted: $REVIEW_TIME (✓ after commit)"
        PR_READY=true
        break
      else
        echo ""
        print_info "Found comment from @$REVIEW_AUTHOR, but it's older than latest commit"
        echo "  Latest commit: $LATEST_COMMIT_TIME"
        echo "  Review posted: $REVIEW_TIME (✗ before commit)"
        echo ""

        # Smart assessment: Check if old review issues are already resolved
        ASSESS_SCRIPT="$RITE_LIB_DIR/core/assess-review-issues.sh"
        if [ -f "$ASSESS_SCRIPT" ]; then
          print_info "Assessing old review to check if issues are resolved..."

          # Use process substitution (no temp files) to pass review content
          ASSESSMENT_RESULT=$("$ASSESS_SCRIPT" "$PR_NUMBER" <(echo "$LATEST_REVIEW") 2>/dev/null || echo "ASSESSMENT_FAILED")

          if [ "$ASSESSMENT_RESULT" = "NO_ACTIONABLE_ITEMS" ]; then
            print_success "Old review has no actionable items remaining - fixes appear successful!"
            PR_READY=true
            break
          elif [ "$ASSESSMENT_RESULT" = "ASSESSMENT_FAILED" ]; then
            print_info "Could not assess review, continuing to wait for fresh review..."
          else
            print_info "Old review still has actionable items, continuing to wait for fresh review..."
          fi
        else
          print_info "Assessment script not found, continuing to wait for fresh review..."
        fi
      fi
    else
      print_success "Review found from @$REVIEW_AUTHOR!"
      PR_READY=true
      break
    fi
  fi

  # Live countdown for next check
  print_info "No review yet... checking again in ${CHECK_INTERVAL}s (${ELAPSED}s elapsed of ${MAX_TOTAL_WAIT}s max)"

  if [ -t 1 ]; then
    # Interactive terminal - show live countdown
    REMAINING=$CHECK_INTERVAL
    while [ $REMAINING -gt 0 ]; do
      printf "\r⏳ Next check in: %ds..." "$REMAINING"
      sleep 1
      REMAINING=$((REMAINING - 1))
    done
    printf "\r🔍 Checking for review...                          \n"
  else
    # Non-interactive - just sleep
    sleep "$CHECK_INTERVAL"
    echo "🔍 Checking for review..."
  fi

  ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

if [ "$PR_READY" = false ]; then
  print_warning "No automated review found after ${ELAPSED}s"
  echo ""
  echo "The review may still be running. You can:"
  echo "  1. Wait and re-run: $0"
  echo "  2. Check manually: $PR_URL"
  echo "  3. Proceed anyway with merge"
  echo ""
  exit 0
fi

# Review found - success!
if [ -n "${REVIEW_AUTHOR:-}" ] && [ "$REVIEW_AUTHOR" != "null" ]; then
  print_success "Review received from @${REVIEW_AUTHOR}"
else
  print_success "Review received"
fi
echo ""
exit 0
