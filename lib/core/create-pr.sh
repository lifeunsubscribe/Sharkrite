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

# Source review helper for consistent review method handling
source "$RITE_LIB_DIR/utils/review-helper.sh"

# Source PR summary helpers for changes-summary section in PR body
source "$RITE_LIB_DIR/utils/pr-summary.sh"

# Source PR detection for shared commit timestamp utility
source "$RITE_LIB_DIR/utils/pr-detection.sh"

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
print_status() { echo -e "${BLUE}$1${NC}"; }

# Verbose-aware output (requires RITE_VERBOSE=true or --supervised)
source "$RITE_LIB_DIR/utils/logging.sh"

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
    print_status "On $CURRENT_BRANCH branch - looking for worktree for issue #$ISSUE_NUMBER..."

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
      print_info "First run: rite $ISSUE_NUMBER --quick"
      exit 1
    fi
  else
    print_error "Cannot create PR from $CURRENT_BRANCH branch"
    print_info "Either:"
    print_status "  1. Switch to feature branch: git checkout BRANCH_NAME"
    print_status "  2. Provide issue number: $0 ISSUE_NUMBER"
    exit 1
  fi
fi

verbose_header "🔍 Checking for Existing PR"

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
    print_status "PR is draft - marking as ready for review..."
    gh pr ready "$PR_NUMBER" 2>/dev/null || print_warning "Could not mark PR as ready"
  fi

  # Push new commits if needed
  CURRENT_HEAD=$(git rev-parse HEAD)
  PR_HEAD=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')
  PUSHED_NEW_COMMITS=false

  if [ "$CURRENT_HEAD" != "$PR_HEAD" ]; then
    print_status "Pushing new commits to PR..."
    if ! git push origin "$CURRENT_BRANCH"; then
      # Push failed — likely remote ahead of local (foreign commits)
      print_warning "Push rejected — checking for remote divergence"

      source "$RITE_LIB_DIR/utils/divergence-handler.sh"

      if detect_divergence "$CURRENT_BRANCH"; then
        div_result=0
        handle_push_divergence "$CURRENT_BRANCH" "$ISSUE_NUMBER" "$PR_NUMBER" "$AUTO_MODE" || div_result=$?

        if [ $div_result -eq 2 ]; then
          # Re-enter review loop — exit with code 2 so workflow-runner knows
          print_info "Divergence resolved — re-entering review cycle"
          exit 2
        elif [ $div_result -ne 0 ]; then
          print_error "Divergence could not be resolved"
          exit 1
        fi
        # div_result=0: resolved, push succeeded inside handler
      else
        # Push failed for another reason (permissions, network, etc.)
        print_error "Failed to push commits to remote (not a divergence issue)"
        exit 1
      fi
    fi
    PUSHED_NEW_COMMITS=true
    print_success "Pushed new commits"
  else
    print_success "PR #$PR_NUMBER branch is up to date — all commits already pushed"
  fi

  # Update PR body with changes summary if stale or missing.
  # This is separate from the push check because claude-workflow.sh pushes
  # commits before create-pr.sh runs, so the body can be stale even when
  # CURRENT_HEAD == PR_HEAD.
  EXISTING_BODY=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null || echo "")

  if [ "$PUSHED_NEW_COMMITS" = true ] || ! echo "$EXISTING_BODY" | grep -qF "$SUMMARY_START"; then
    print_status "Updating PR description..."
    FRESH_SUMMARY=$(build_changes_summary "$BASE_BRANCH")

    if [ -n "$EXISTING_BODY" ]; then
      UPDATED_BODY=$(replace_changes_summary "$EXISTING_BODY" "$FRESH_SUMMARY")
    else
      ISSUE_LINK=$(echo "$EXISTING_BODY" | grep -oE '(Closes|closes|Fixes|fixes|Resolves|resolves) #[0-9]+' | head -1)
      UPDATED_BODY="## Summary

${ISSUE_LINK:+$ISSUE_LINK}

${FRESH_SUMMARY}"
    fi

    gh pr edit "$PR_NUMBER" --body "$UPDATED_BODY" 2>/dev/null || print_warning "Could not update PR description"
    print_success "PR description updated"
  fi
  echo ""
fi

# If PR doesn't exist, create it
if [ "$PR_EXISTS" = false ]; then
  verbose_header "📝 Creating New Pull Request"

  # If issue number provided, fetch issue details
  if [ ! -z "$ISSUE_NUMBER" ]; then
    print_status "Fetching issue #$ISSUE_NUMBER details..."

    ISSUE_JSON=$(gh issue view $ISSUE_NUMBER --json title,body,labels 2>/dev/null || echo "")

    if [ ! -z "$ISSUE_JSON" ]; then
      ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
      ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body')
      ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

      print_success "Issue: $ISSUE_TITLE"
    fi
  fi

  # Generate PR title — prefer NORMALIZED_SUBJECT (clean, <=50 chars, prefixed)
  if [ -n "${NORMALIZED_SUBJECT:-}" ]; then
    PR_TITLE="$NORMALIZED_SUBJECT"
  elif [ ! -z "$ISSUE_NUMBER" ] && [ ! -z "$ISSUE_TITLE" ]; then
    PR_TITLE="$ISSUE_TITLE"
  else
    # Extract title from branch name
    PR_TITLE=$(echo "$CURRENT_BRANCH" | sed 's/.*\///' | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
  fi

  # Build changes summary (marked section)
  CHANGES_SUMMARY=$(build_changes_summary "$BASE_BRANCH")

  # Build PR body
  PR_BODY=$(cat <<EOF
## Summary

$(if [ ! -z "$ISSUE_NUMBER" ]; then echo "Closes #${ISSUE_NUMBER}"; fi)

${ISSUE_TITLE:-"Changes to ${CURRENT_BRANCH}"}

${CHANGES_SUMMARY}

## Testing

- [x] Code builds successfully
- [x] Unit tests pass locally
- [ ] Integration tests pass (CI will verify)
- [ ] Sharkrite code review pending

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

# Early sensitivity detection: identify file patterns that will inform review focus.
# These do NOT block anything — they give early awareness of what the review will scrutinize.
print_status "Checking review sensitivity areas..."

set +e
sensitivity_hints=$(detect_sensitivity_areas "$PR_NUMBER" 2>/dev/null)
set -e

if [ -n "$sensitivity_hints" ]; then
  # Extract category names from "### Sensitivity: ..." headers
  sensitivity_areas=$(echo "$sensitivity_hints" | grep "^### Sensitivity:" | sed 's/^### Sensitivity: //' | paste -sd ', ' -)
  print_info "Review focus areas: $sensitivity_areas"
else
  print_success "No special sensitivity areas detected"
fi
echo ""

# Trigger local Sharkrite review
if [ "$AUTO_MODE" = true ]; then
  trigger_local_review "$PR_NUMBER" --auto || {
    print_error "Local review failed"
    exit 1
  }
else
  trigger_local_review "$PR_NUMBER" || {
    print_error "Local review failed"
    exit 1
  }
fi

print_success "Review posted to PR #$PR_NUMBER"
echo ""
exit 0
