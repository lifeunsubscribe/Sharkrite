#!/usr/bin/env bash
# batch-process-issues.sh
# Batch process multiple GitHub issues in unsupervised mode
# Usage:
#   rite 19 21 31 32              # Process specific issues
#   rite --label bug              # Process all issues with label
#   rite --milestone v1.0         # Process all issues in milestone
#   rite --followup               # Auto-discover follow-up pairs (max 4)
#
# Features:
#   - Unsupervised batch processing (--auto mode for all issues)
#   - Session limit enforcement (8 issues OR 4 hours)
#   - Smart follow-up pairing (fix → merge parent PR)
#   - Progress tracking and notifications
#   - Automatic worktree management
#   - Comprehensive summary report

set -euo pipefail

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Source libraries
source "$RITE_LIB_DIR/utils/session-tracker.sh"
source "$RITE_LIB_DIR/utils/notifications.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
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

# Parse arguments
ISSUE_LIST=()
FILTER_TYPE=""
FILTER_VALUE=""
SMART_WAIT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --smart-wait)
      SMART_WAIT=true
      shift
      ;;
    --followup|--follow-ups)
      FILTER_TYPE="followup"
      shift
      ;;
    --label)
      FILTER_TYPE="label"
      FILTER_VALUE="$2"
      shift 2
      ;;
    --milestone)
      FILTER_TYPE="milestone"
      FILTER_VALUE="$2"
      shift 2
      ;;
    --state)
      FILTER_TYPE="state"
      FILTER_VALUE="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_LIST+=("$1")
      fi
      shift
      ;;
  esac
done

# Fetch issues if filter specified
if [ -n "$FILTER_TYPE" ]; then
  print_header "📋 Fetching Issues with Filter"
  print_info "Filter: $FILTER_TYPE = $FILTER_VALUE"

  case "$FILTER_TYPE" in
    followup)
      print_info "🔍 Tech Debt Management Mode"
      echo ""

      # Fetch all tech-debt issues with full body content
      DEBT_ISSUES=$(gh issue list --label "tech-debt" --state open --json number,title,labels,body 2>/dev/null || echo "")

      if [ -z "$DEBT_ISSUES" ]; then
        print_success "No tech debt issues found - clean slate!"
        exit 0
      fi

      # Count total debt issues
      TOTAL_DEBT=$(echo "$DEBT_ISSUES" | jq -s 'length')

      # Parse task counts from issue bodies
      TOTAL_TASKS=0
      HIGH_TASKS=0
      MEDIUM_TASKS=0
      LOW_TASKS=0
      HIGH_ISSUES=0
      MEDIUM_ISSUES=0
      LOW_ISSUES=0

      while IFS= read -r issue_json; do
        ISSUE_BODY=$(echo "$issue_json" | jq -r '.body // ""')

        # Count tasks by priority in this issue's body
        CRITICAL_IN_ISSUE=$(echo "$ISSUE_BODY" | grep -c "CRITICAL" || true)
        HIGH_IN_ISSUE=$(echo "$ISSUE_BODY" | grep -c "HIGH" || true)
        MEDIUM_IN_ISSUE=$(echo "$ISSUE_BODY" | grep -c "MEDIUM" || true)
        LOW_IN_ISSUE=$(echo "$ISSUE_BODY" | grep -c "LOW" || true)

        # Add CRITICAL to HIGH count (treat as HIGH priority)
        HIGH_IN_ISSUE=$((HIGH_IN_ISSUE + CRITICAL_IN_ISSUE))

        # Accumulate totals
        HIGH_TASKS=$((HIGH_TASKS + HIGH_IN_ISSUE))
        MEDIUM_TASKS=$((MEDIUM_TASKS + MEDIUM_IN_ISSUE))
        LOW_TASKS=$((LOW_TASKS + LOW_IN_ISSUE))

        # Count issues that contain each priority
        [ $HIGH_IN_ISSUE -gt 0 ] && HIGH_ISSUES=$((HIGH_ISSUES + 1))
        [ $MEDIUM_IN_ISSUE -gt 0 ] && MEDIUM_ISSUES=$((MEDIUM_ISSUES + 1))
        [ $LOW_IN_ISSUE -gt 0 ] && LOW_ISSUES=$((LOW_ISSUES + 1))
      done < <(echo "$DEBT_ISSUES" | jq -c '.[]')

      TOTAL_TASKS=$((HIGH_TASKS + MEDIUM_TASKS + LOW_TASKS))

      # Generate comprehensive tech debt report
      print_header "📊 Tech Debt Report"
      echo -e "${YELLOW}Total Outstanding: $TOTAL_DEBT issue(s) containing $TOTAL_TASKS task(s)${NC}"
      echo ""

      echo "Task Priority Breakdown:"
      if [ "$HIGH_TASKS" -gt 0 ]; then
        echo -e "${RED}  🔴 High:   $HIGH_TASKS task(s) across $HIGH_ISSUES issue(s)${NC}"
      fi
      if [ "$MEDIUM_TASKS" -gt 0 ]; then
        echo -e "${YELLOW}  🟡 Medium: $MEDIUM_TASKS task(s) across $MEDIUM_ISSUES issue(s)${NC}"
      fi
      if [ "$LOW_TASKS" -gt 0 ]; then
        echo -e "${BLUE}  🔵 Low:    $LOW_TASKS task(s) across $LOW_ISSUES issue(s)${NC}"
      fi
      echo ""

      # Show detailed breakdown of what each issue concerns
      print_info "Issues in Tech Debt:"
      echo ""
      echo "$DEBT_ISSUES" | jq -s '.[:8]' | jq -r '.[] |
        "  #\(.number): \(.title)" +
        (if (.labels[] | select(.name == "High Priority")) then " [🔴 HIGH]"
         elif (.labels[] | select(.name == "Medium Priority")) then " [🟡 MEDIUM]"
         elif (.labels[] | select(.name == "Low Priority")) then " [🔵 LOW]"
         else "" end)' | sed 's/^/  /'

      if [ "$TOTAL_DEBT" -gt 8 ]; then
        echo ""
        echo -e "${YELLOW}  ... and $((TOTAL_DEBT - 8)) more issue(s)${NC}"
      fi
      echo ""

      # Fetch up to max issues for batch processing (prioritize HIGH first)
      MAX_ISSUES="${RITE_MAX_ISSUES_PER_SESSION:-8}"
      ISSUE_LIST=($(echo "$DEBT_ISSUES" | jq -r '.number' | head -$MAX_ISSUES))

      print_success "Queued ${#ISSUE_LIST[@]} tech-debt issues for processing"
      echo ""
      ;;
    label)
      FETCHED_ISSUES=$(gh issue list --label "$FILTER_VALUE" --state open --json number --jq '.[].number' | tr '\n' ' ')
      ;;
    milestone)
      FETCHED_ISSUES=$(gh issue list --milestone "$FILTER_VALUE" --state open --json number --jq '.[].number' | tr '\n' ' ')
      ;;
    state)
      FETCHED_ISSUES=$(gh issue list --state "$FILTER_VALUE" --json number --jq '.[].number' | tr '\n' ' ')
      ;;
  esac

  # Convert to array (unless already built in followup mode)
  if [ "$FILTER_TYPE" != "followup" ]; then
    read -ra ISSUE_LIST <<< "$FETCHED_ISSUES"

    print_success "Found ${#ISSUE_LIST[@]} issues"
    echo "Issues: ${ISSUE_LIST[*]}"
    echo ""
  fi
fi

# Validate we have issues to process
if [ ${#ISSUE_LIST[@]} -eq 0 ]; then
  print_error "No issues specified"
  echo ""
  echo "Usage:"
  echo "  rite 19 21 31 32              # Process specific issues"
  echo "  rite --label bug              # Process all issues with label"
  echo "  rite --milestone v1.0         # Process all issues in milestone"
  echo "  rite --followup               # Auto-discover follow-up pairs (max 4)"
  echo ""
  exit 1
fi

# Initialize session tracking
init_session "batch-${ISSUE_LIST[0]}-$(date +%s)"

# Batch processing state
BATCH_START_TIME=$(date +%s)
TOTAL_ISSUES=${#ISSUE_LIST[@]}
COMPLETED_ISSUES=0
FAILED_ISSUES=()
BLOCKED_ISSUES=()
SKIPPED_ISSUES=()

# Summary arrays
# NOTE: Associative arrays require bash 4+, but macOS ships with bash 3.2
# For now, skipping detailed status tracking - using simple indexed arrays instead
declare -a SECURITY_UPDATES=()   # Track security doc updates
declare -a NEW_ISSUES_CREATED=() # Track new tech-debt issues
declare -a FAILED_PAIRS=()       # Track failed parent-child pairs

print_header "🚀 Batch Processing Started"
echo "Total Issues: $TOTAL_ISSUES"
echo "Issues: ${ISSUE_LIST[*]}"
echo "Mode: Unsupervised (--auto)"
echo ""

# Pre-start checks
print_info "Running pre-start checks..."

# Check if any issues require AWS credentials (infrastructure, deployment, AWS service changes)
AWS_REQUIRED=false
for ISSUE_NUM in "${ISSUE_LIST[@]}"; do
  ISSUE_LABELS=$(gh issue view "$ISSUE_NUM" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
  ISSUE_TITLE=$(gh issue view "$ISSUE_NUM" --json title --jq '.title' 2>/dev/null || echo "")

  # Check if issue involves AWS operations
  if echo "$ISSUE_LABELS,$ISSUE_TITLE" | grep -qiE "(infrastructure|deployment|aws|lambda|cognito|dynamodb|s3|ses|sns)"; then
    AWS_REQUIRED=true
    break
  fi
done

# Only check AWS credentials if actually needed
if [ "$AWS_REQUIRED" = true ]; then
  print_info "Checking AWS credentials (required for infrastructure changes)..."
  if ! aws sts get-caller-identity &>/dev/null; then
    print_error "AWS credentials expired"
    print_info "Run: aws sso login --profile ${RITE_AWS_PROFILE}"
    send_blocker_notification "AWS Credentials Expired" "batch-${ISSUE_LIST[0]}" "" "" "This workflow involves infrastructure/AWS changes that require valid AWS credentials."
    exit 1
  fi
  print_success "AWS credentials valid"
else
  print_info "AWS credentials not required for these issues"
  # Export flag to skip AWS checks in nested workflow scripts
  export SKIP_AWS_CHECK=true
fi

# Check session limits upfront
SESSION_STATE=$(get_session_info)
ISSUES_COMPLETED=$(echo "$SESSION_STATE" | jq -r '.issues_completed')
SESSION_START=$(echo "$SESSION_STATE" | jq -r '.start_time')
CURRENT_TIME=$(date +%s)
ELAPSED_HOURS=$(awk "BEGIN {print ($CURRENT_TIME - $SESSION_START) / 3600}")

# Validate batch won't exceed limits
PROJECTED_TOTAL=$((ISSUES_COMPLETED + TOTAL_ISSUES))
MAX_ISSUES_LIMIT="${RITE_MAX_ISSUES_PER_SESSION:-8}"

if [ "$PROJECTED_TOTAL" -gt "$MAX_ISSUES_LIMIT" ]; then
  print_warning "Batch would exceed session limit ($MAX_ISSUES_LIMIT issues)"
  print_info "Current: $ISSUES_COMPLETED issues completed"
  print_info "Batch size: $TOTAL_ISSUES issues"
  print_info "Projected: $PROJECTED_TOTAL issues total"
  echo ""

  # Calculate how many we can do
  ALLOWED_ISSUES=$((MAX_ISSUES_LIMIT - ISSUES_COMPLETED))

  if [ "$ALLOWED_ISSUES" -le 0 ]; then
    print_error "Session limit already reached"
    print_info "Start new session to continue"
    exit 1
  fi

  print_warning "Limiting batch to $ALLOWED_ISSUES issues"
  ISSUE_LIST=("${ISSUE_LIST[@]:0:$ALLOWED_ISSUES}")
  TOTAL_ISSUES=${#ISSUE_LIST[@]}
  echo ""
fi

print_success "Pre-start checks passed"
echo ""

# Pre-flight blocker scan: Check all issues for potential blockers upfront
print_header "🔍 Pre-Flight Blocker Scan"
print_info "Scanning all issues for potential blockers before starting..."
echo ""

PREFLIGHT_BLOCKERS=()
declare -A PREFLIGHT_BLOCKER_DETAILS

for ISSUE_NUM in "${ISSUE_LIST[@]}"; do
  # Check if issue has an open PR
  PR_NUMBER=$(gh pr list --search "fixes #${ISSUE_NUM} OR closes #${ISSUE_NUM} in:title in:body" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

  if [ -n "$PR_NUMBER" ]; then
    print_info "Issue #$ISSUE_NUM has PR #$PR_NUMBER - checking for blockers..."

    # Run blocker checks (pass "unsupervised" since this is batch mode)
    BLOCKER_CHECK=$(check_blockers "pre-merge" "$PR_NUMBER" "$ISSUE_NUM" "unsupervised" 2>&1) || {
      BLOCKER_FOUND=true
      # Extract blocker type from check_blockers output
      BLOCKER_TYPE=$(echo "$BLOCKER_CHECK" | grep -o "BLOCKER:.*" | head -1 || echo "Unknown blocker")
      PREFLIGHT_BLOCKERS+=("$ISSUE_NUM")
      PREFLIGHT_BLOCKER_DETAILS["$ISSUE_NUM"]="$BLOCKER_TYPE (PR #$PR_NUMBER)"
      print_warning "⚠️  Issue #$ISSUE_NUM: $BLOCKER_TYPE"
    }
  fi
done

if [ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]; then
  echo ""
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_warning "Pre-Flight Blockers Detected"
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  print_info "The following issues have potential blockers:"
  echo ""

  for ISSUE_NUM in "${PREFLIGHT_BLOCKERS[@]}"; do
    echo "  • Issue #$ISSUE_NUM: ${PREFLIGHT_BLOCKER_DETAILS[$ISSUE_NUM]}"
  done

  echo ""
  print_info "These issues will be deferred during batch processing"
  print_info "Workflow will continue with non-blocked issues"
  echo ""
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
else
  print_success "No blockers detected in pre-flight scan"
  echo ""
fi

# Send batch start notification
send_notification_all "🚀 *Batch Processing Started*
*Total Issues:* $TOTAL_ISSUES
*Issues:* ${ISSUE_LIST[*]}
*Pre-flight Blockers:* ${#PREFLIGHT_BLOCKERS[@]}
*Mode:* Unsupervised" "normal"

echo "DEBUG: About to start processing ${#ISSUE_LIST[@]} issues" >&2
echo "DEBUG: ISSUE_LIST=${ISSUE_LIST[*]}" >&2

# Process each issue
for ISSUE_NUM in "${ISSUE_LIST[@]}"; do
  echo "DEBUG: Starting loop iteration for issue $ISSUE_NUM" >&2
  ISSUE_START_TIME=$(date +%s)
  CURRENT_ISSUE=$((COMPLETED_ISSUES + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]} + ${#SKIPPED_ISSUES[@]} + 1))

  print_header "📌 Processing Issue #$ISSUE_NUM ($CURRENT_ISSUE/$TOTAL_ISSUES)"

  # Fetch issue details
  ISSUE_DETAILS=$(gh issue view "$ISSUE_NUM" --json title,labels,state 2>/dev/null || echo "{}")

  if [ "$ISSUE_DETAILS" = "{}" ]; then
    print_error "Issue #$ISSUE_NUM not found"
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="not_found"
    continue
  fi

  ISSUE_TITLE=$(echo "$ISSUE_DETAILS" | jq -r '.title')
  ISSUE_STATE=$(echo "$ISSUE_DETAILS" | jq -r '.state')

  print_info "Title: $ISSUE_TITLE"
  print_info "State: $ISSUE_STATE"
  echo ""

  # Skip if already closed
  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    print_warning "Issue already closed - skipping"
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="already_closed"
    echo ""
    continue
  fi

  # Check if this is a follow-up issue with parent PR dependency
  ISSUE_LABELS=$(gh issue view "$ISSUE_NUM" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
  PARENT_PR=""

  if echo "$ISSUE_LABELS" | grep -q "parent-pr:"; then
    # Extract parent PR number from label (format: parent-pr:39)
    PARENT_PR=$(echo "$ISSUE_LABELS" | grep -oE 'parent-pr:[0-9]+' | cut -d: -f2)

    if [ -n "$PARENT_PR" ]; then
      # Check if parent PR is still open
      PARENT_PR_STATE=$(gh pr view "$PARENT_PR" --json state --jq '.state' 2>/dev/null || echo "")

      if [ "$PARENT_PR_STATE" = "OPEN" ]; then
        # Check if parent issue is also in this batch (deliberate pairing)
        PARENT_ISSUE=$(gh pr view "$PARENT_PR" --json body --jq '.body' 2>/dev/null | grep -oE 'Closes #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")

        # Check if parent issue is in our queue
        PARENT_IN_QUEUE=false
        for queued_issue in "${ISSUE_LIST[@]}"; do
          if [ "$queued_issue" = "$PARENT_ISSUE" ]; then
            PARENT_IN_QUEUE=true
            break
          fi
        done

        if [ "$PARENT_IN_QUEUE" = true ]; then
          print_success "✅ Parent issue #$PARENT_ISSUE is in queue - this is a follow-up pair"
          print_info "Follow-up work will update parent PR #$PARENT_PR before merging parent issue"
        else
          # Parent not in queue, defer this issue
          print_warning "⏸️  Parent PR #$PARENT_PR is still open - deferring issue #$ISSUE_NUM"
          print_info "This follow-up issue will be processed after parent PR merges"
          SKIPPED_ISSUES+=("$ISSUE_NUM")
          ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"
          echo ""
          continue
        fi
      elif [ "$PARENT_PR_STATE" = "MERGED" ]; then
        print_success "✅ Parent PR #$PARENT_PR is merged - proceeding with follow-up"
      fi
    fi
  fi

  # Check if issue already has open PR (must have "Closes #XX" in body)
  EXISTING_PR=""
  for pr_num in $(gh pr list --state open --json number --jq '.[].number' 2>/dev/null); do
    if gh pr view "$pr_num" --json body --jq '.body' 2>/dev/null | grep -q "Closes #${ISSUE_NUM}\$\|Closes #${ISSUE_NUM}[^0-9]"; then
      EXISTING_PR="$pr_num"
      break
    fi
  done

  if [ -n "$EXISTING_PR" ]; then
    # If smart-wait enabled and this looks like a parent issue, wait for review
    if [ "$SMART_WAIT" = true ]; then
      # Check if this issue's PR was just updated by a previous issue in batch
      PR_UPDATED=$(gh pr view "$EXISTING_PR" --json commits --jq '.commits[-1].committedDate' 2>/dev/null || echo "")
      REVIEW_TIME=$(gh pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt' 2>/dev/null || echo "")

      if [ -n "$PR_UPDATED" ] && [ -n "$REVIEW_TIME" ] && [[ "$PR_UPDATED" > "$REVIEW_TIME" ]]; then
        print_info "⏰ Smart Wait: PR #$EXISTING_PR updated after review"
        print_info "Waiting for new review (timeout: 15 minutes, poll every 2 min)..."
        echo ""

        WAIT_START=$(date +%s)
        MAX_WAIT=$((15 * 60))  # 15 minutes
        POLL_INTERVAL=120       # 2 minutes

        while true; do
          sleep $POLL_INTERVAL

          # Check for newer review
          NEW_REVIEW_TIME=$(gh pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt' 2>/dev/null || echo "")

          if [ -n "$NEW_REVIEW_TIME" ] && [[ "$NEW_REVIEW_TIME" > "$PR_UPDATED" ]]; then
            print_success "✅ New review detected! Continuing with merge workflow..."
            echo ""
            break
          fi

          ELAPSED=$(($(date +%s) - WAIT_START))
          if [ $ELAPSED -ge $MAX_WAIT ]; then
            print_warning "⏱️  Timeout: No review after 15 minutes"

            # Send Slack notification
            send_notification "⏱️ Manual Intervention Needed" "Issue #$ISSUE_NUM: PR #$EXISTING_PR timeout waiting for review. Run: \`rite $ISSUE_NUM\`" "warning"

            print_info "📱 Slack notification sent"
            print_info "Manual run needed: rite $ISSUE_NUM"
            echo ""

            SKIPPED_ISSUES+=("$ISSUE_NUM")
            ISSUE_STATUS["$ISSUE_NUM"]="review_timeout"
            ISSUE_PR["$ISSUE_NUM"]="$EXISTING_PR"
            continue 2  # Skip to next issue in outer loop
          fi

          print_info "Still waiting... ($((ELAPSED / 60))/$((MAX_WAIT / 60)) min)"
        done
      fi
    fi

    # Check if we're already in this PR's branch (avoid conflicts)
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    PR_BRANCH=$(gh pr view "$EXISTING_PR" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$PR_BRANCH" ] && [ "$CURRENT_BRANCH" = "$PR_BRANCH" ]; then
      print_warning "Already in this issue's branch ($PR_BRANCH) - skipping to avoid conflicts"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="in_current_branch"
      ISSUE_PR["$ISSUE_NUM"]="$EXISTING_PR"
      echo ""
      continue
    fi

    # Otherwise, proceed - workflow will use worktree for this PR's branch
    print_info "Will continue work on PR #$EXISTING_PR in worktree"
    echo ""
  fi

  # Run workflow in unsupervised mode
  print_info "Starting workflow-runner.sh --auto..."
  echo ""

  # Export BATCH_MODE flag so nested scripts know we're in batch processing
  export BATCH_MODE=true

  # Run workflow with exit code handling
  if "$RITE_LIB_DIR/core/workflow-runner.sh" "$ISSUE_NUM" --unsupervised; then
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    # Get PR number from latest PR for this issue
    PR_NUMBER=$(gh pr list --search "issue:$ISSUE_NUM" --state all --limit 1 --json number --jq '.[0].number' 2>/dev/null || echo "")

    print_success "Issue #$ISSUE_NUM completed successfully"
    if [ -n "$PR_NUMBER" ]; then
      print_info "PR: #$PR_NUMBER"
      ISSUE_PR["$ISSUE_NUM"]="$PR_NUMBER"

      # Capture branch name and changes summary
      BRANCH_NAME=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
      if [ -n "$BRANCH_NAME" ]; then
        ISSUE_BRANCH["$ISSUE_NUM"]="$BRANCH_NAME"
      fi

      # Capture changes summary (files changed + lines)
      PR_STATS=$(gh pr view "$PR_NUMBER" --json additions,deletions,changedFiles --jq '"\(.changedFiles) files, +\(.additions)/-\(.deletions) lines"' 2>/dev/null || echo "")
      if [ -n "$PR_STATS" ]; then
        PR_CHANGES["$PR_NUMBER"]="$PR_STATS"
      fi

      # Check for security doc updates
      SECURITY_DOC_UPDATED=$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null | grep -c "docs/security/DEVELOPMENT-GUIDE.md" || true)
      if [ "$SECURITY_DOC_UPDATED" -gt 0 ]; then
        SECURITY_UPDATES+=("PR #$PR_NUMBER: Updated DEVELOPMENT-GUIDE.md with findings from #$ISSUE_NUM")
      fi

      # Check for new tech-debt issues created
      NEW_DEBT_ISSUE=$(gh issue list --label "tech-debt,parent-pr:$PR_NUMBER" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
      if [ -n "$NEW_DEBT_ISSUE" ]; then
        NEW_ISSUES_CREATED+=("Issue #$NEW_DEBT_ISSUE (from PR #$PR_NUMBER)")
      fi
    fi
    print_info "Duration: ${ISSUE_DURATION}s"
    echo ""

    COMPLETED_ISSUES=$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS["$ISSUE_NUM"]="completed"

    # Send success notification if smart-wait was used (means auto-merge happened)
    if [ "$SMART_WAIT" = true ] && [ -n "$PR_NUMBER" ]; then
      send_notification "✅ Auto-Merge Success!" "Issue #$ISSUE_NUM completed and PR #$PR_NUMBER merged automatically! Duration: $((ISSUE_DURATION / 60))m" "success"
    fi

    # Update session state
    record_issue_completion "$ISSUE_NUM" "$PR_NUMBER"

  else
    EXIT_CODE=$?
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_error "Issue #$ISSUE_NUM failed (exit code: $EXIT_CODE)"
    print_info "Duration: ${ISSUE_DURATION}s"
    echo ""

    if [ $EXIT_CODE -eq 10 ]; then
      # Blocker detected - defer instead of stopping
      print_warning "⏸️  Blocker detected - deferring issue #$ISSUE_NUM"
      BLOCKED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="blocked"

      # Send blocker notification
      send_blocker_notification "Workflow Blocker" "$ISSUE_NUM"

      print_info "Will retry after processing remaining issues"
      echo ""
      # Continue with next issue instead of breaking

    else
      # Other failure
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="failed"
    fi
  fi

  # Check session limits after each issue
  SESSION_STATE=$(get_session_info)
  ISSUES_COMPLETED=$(echo "$SESSION_STATE" | jq -r '.issues_completed')

  if [ "$ISSUES_COMPLETED" -ge "$MAX_ISSUES_LIMIT" ]; then
    print_warning "Session limit reached ($MAX_ISSUES_LIMIT issues)"
    print_info "Stopping batch processing"
    break
  fi

  # Small delay between issues (avoid rate limiting)
  if [ "$CURRENT_ISSUE" -lt "$TOTAL_ISSUES" ]; then
    print_info "Waiting 5s before next issue..."
    sleep 5
    echo ""
  fi
done

# Calculate final stats
BATCH_END_TIME=$(date +%s)
TOTAL_DURATION=$((BATCH_END_TIME - BATCH_START_TIME))
TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))

# Generate summary report
# Retry blocked issues (they may have follow-up issues created now)
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  print_header "🔄 Retrying Previously Blocked Issues"

  echo "Found ${#BLOCKED_ISSUES[@]} blocked issue(s) - checking if follow-ups were created..."
  echo ""

  RETRY_SUCCESS=()
  STILL_BLOCKED=()

  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    # Check if follow-up issue was created for this blocker
    FOLLOWUP_ISSUE=$(gh issue list --search "parent-pr in:body in:title" --label "review-follow-up" --state open --json number,body --jq ".[] | select(.body | contains(\"#$ISSUE_NUM\")) | .number" 2>/dev/null | head -1 || echo "")

    if [ -n "$FOLLOWUP_ISSUE" ]; then
      print_info "Issue #$ISSUE_NUM blocked → Follow-up #$FOLLOWUP_ISSUE created"
      print_success "No retry needed - workflow created follow-up issue"
      RETRY_SUCCESS+=("$ISSUE_NUM")
    else
      print_warning "Issue #$ISSUE_NUM still blocked (no follow-up created)"
      STILL_BLOCKED+=("$ISSUE_NUM")
    fi
    echo ""
  done

  # Update blocked list to only include still-blocked items
  BLOCKED_ISSUES=("${STILL_BLOCKED[@]}")
fi

print_header "📊 Batch Processing Summary"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Overall Statistics"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total Issues:     $TOTAL_ISSUES"
echo "Processed:        $TOTAL_PROCESSED"
echo "Completed:        $COMPLETED_ISSUES"
echo "Failed:           ${#FAILED_ISSUES[@]}"
echo "Blocked:          ${#BLOCKED_ISSUES[@]}"
echo "Skipped:          ${#SKIPPED_ISSUES[@]}"
echo "Total Duration:   ${TOTAL_DURATION}s ($((TOTAL_DURATION / 60))m)"
echo ""

# Detailed issue breakdown
if [ $COMPLETED_ISSUES -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Completed Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$ISSUE_NUM]}" = "completed" ]; then
      DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
      PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
      echo "  ✅ Issue #$ISSUE_NUM → PR #$PR_NUM (${DURATION}s)"
    fi
  done | sort -t'#' -k2 -n
  echo ""
fi

if [ ${#FAILED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Failed Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${FAILED_ISSUES[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    echo "  ❌ Issue #$ISSUE_NUM (${DURATION}s)"
  done
  echo ""
fi

if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Still Blocked Issues (Manual Intervention Needed)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    echo "  🚨 Issue #$ISSUE_NUM (${DURATION}s)"
  done
  echo ""
  print_warning "These issues require manual review - no follow-up was created"
  echo ""
fi

if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Skipped Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${SKIPPED_ISSUES[@]}"; do
    REASON=${ISSUE_STATUS[$ISSUE_NUM]:-"unknown"}
    echo "  ⏭️  Issue #$ISSUE_NUM ($REASON)"
  done
  echo ""
fi

# Build comprehensive Slack summary
NOTIFICATION_MESSAGE="📊 *Batch Processing Complete*

*Overall Statistics:*
• Total Issues: $TOTAL_ISSUES
• Completed: $COMPLETED_ISSUES ✅
• Failed: ${#FAILED_ISSUES[@]} ❌
• Blocked: ${#BLOCKED_ISSUES[@]} 🚨
• Skipped: ${#SKIPPED_ISSUES[@]} ⏭️
• Duration: $((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s
• Success Rate: $((COMPLETED_ISSUES * 100 / TOTAL_ISSUES))%"

# Add merged branches section
if [ $COMPLETED_ISSUES -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*🌿 Merged Branches:*"
  for ISSUE_NUM in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$ISSUE_NUM]}" = "completed" ]; then
      PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-""}
      BRANCH=${ISSUE_BRANCH[$ISSUE_NUM]:-"unknown"}
      CHANGES=${PR_CHANGES[$PR_NUM]:-"N/A"}
      NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• \`$BRANCH\` → PR #$PR_NUM ($CHANGES)"
    fi
  done | sort -t'#' -k2 -n
fi

# Add security doc updates section
if [ ${#SECURITY_UPDATES[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*🔒 Security Doc Updates:*"
  for update in "${SECURITY_UPDATES[@]}"; do
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• $update"
  done
fi

# Add new issues created section
if [ ${#NEW_ISSUES_CREATED[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*📝 New \`tech-debt\` Issues:*"
  for issue in "${NEW_ISSUES_CREATED[@]}"; do
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• $issue"
  done
fi

# Add failed pairs section (needs manual restart)
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*⚠️  Failed Pairs (Manual Restart Needed):*"
  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• Issue #$ISSUE_NUM (PR #$PR_NUM) - Run: \`rite $ISSUE_NUM\`"
  done
fi

# Add session stats
SESSION_STATE=$(get_session_info)
TOTAL_TOKENS=$(echo "$SESSION_STATE" | jq -r '.tokens_used // 0')
SESSION_DURATION=$(echo "$SESSION_STATE" | jq -r '.session_start // 0')
if [ "$SESSION_DURATION" != "0" ]; then
  SESSION_ELAPSED=$(( $(date +%s) - SESSION_DURATION ))
  SESSION_HOURS=$(( SESSION_ELAPSED / 3600 ))
  SESSION_MINS=$(( (SESSION_ELAPSED % 3600) / 60 ))

  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*📈 Session Stats:*
• Total Time: ${SESSION_HOURS}h ${SESSION_MINS}m
• Issues Processed: $(echo "$SESSION_STATE" | jq -r '.issues_completed // 0')
• Approx Tokens: $TOTAL_TOKENS"
fi

send_notification_all "$NOTIFICATION_MESSAGE" "normal"

# Exit with appropriate code
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  print_warning "Batch paused due to blocker"
  exit 10
elif [ ${#FAILED_ISSUES[@]} -gt 0 ] && [ $COMPLETED_ISSUES -eq 0 ]; then
  print_error "All issues failed"
  exit 1
elif [ $COMPLETED_ISSUES -eq 0 ]; then
  print_warning "No issues completed"
  exit 0
else
  print_success "Batch processing completed"
  exit 0
fi

# Helper function: Create batch resume script
create_batch_resume_script() {
  local blocked_issue="$1"
  shift
  local remaining_issues=("$@")

  # Filter out already processed issues
  local resume_list=()
  local found_blocked=false

  for issue in "${remaining_issues[@]}"; do
    if [ "$found_blocked" = true ]; then
      resume_list+=("$issue")
    fi

    if [ "$issue" = "$blocked_issue" ]; then
      found_blocked=true
      resume_list+=("$issue")  # Include blocked issue for retry
    fi
  done

  # Create resume directory
  mkdir -p "${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/.resume"

  local resume_script="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/.resume/resume-batch-${blocked_issue}.sh"

  cat > "$resume_script" <<EOF
#!/bin/bash
# Auto-generated batch resume script
# Blocked on issue: #${blocked_issue}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

echo "🔄 Resuming batch processing..."
echo "Remaining issues: ${resume_list[*]}"
echo ""

# Resume with remaining issues
rite ${resume_list[*]}
EOF

  chmod +x "$resume_script"

  print_success "Batch resume script created: $resume_script"
}
