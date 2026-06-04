#!/bin/bash
# merge-pr.sh
# Complete PR merge workflow with validation
# Usage:
#   rite merge <pr-number>   # Merge specific PR
#   rite merge               # Merge PR for current branch
#
# Optional Environment Variables:
#   SLACK_WEBHOOK - Slack webhook URL for deep clean notifications
#                   Export in your shell: export SLACK_WEBHOOK="https://hooks.slack.com/..."

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_MERGE_PR_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_MERGE_PR_LOADED=true

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Source portable command wrappers (stat mtime — BSD/GNU compat)
source "$RITE_LIB_DIR/utils/portable-cmds.sh"

# Source scratchpad manager
if [ -f "$RITE_LIB_DIR/utils/scratchpad-manager.sh" ]; then
  source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"
fi

# Source stash manager
source "$RITE_LIB_DIR/utils/stash-manager.sh"

# Source marker constants
source "$RITE_LIB_DIR/utils/markers.sh"

# Source git helpers (provides git_fetch_safe — retries with backoff, fails loudly)
source "$RITE_LIB_DIR/utils/git-helpers.sh"

# Source gh retry helper (provides gh_safe — retries 429/5xx, handles not-found)
source "$RITE_LIB_DIR/utils/gh-retry.sh"

# Source provider abstraction
source "$RITE_LIB_DIR/providers/provider-interface.sh"
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

# Parse arguments
AUTO_MODE=false
PR_NUMBER=""
for arg in "$@"; do
  if [[ "$arg" == "--auto" ]]; then
    AUTO_MODE=true
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="$arg"
  fi
done

CURRENT_BRANCH=$(git branch --show-current)
BASE_BRANCH="main"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check dependencies
if ! command -v gh &> /dev/null; then
  echo -e "${RED}❌ GitHub CLI required: brew install gh${NC}"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo -e "${RED}❌ jq required: brew install jq${NC}"
  exit 1
fi

# Function to print colored messages
print_header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

print_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
  echo -e "${RED}❌ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

# File-scope temp-file cleanup. Two places set EXIT/ERR/INT/TERM traps that
# reference cleanup_temp_files: line ~228 (inside update_security_guide_from_pr)
# and line ~1473 (inside the main merge body). The 1473 trap fires even when the
# 228 path was never taken (typical for a clean merge that doesn't trigger the
# security-guide update), so if the function were only defined inside
# update_security_guide_from_pr it would be undefined at trap-fire time, producing
# 'cleanup_temp_files: command not found' and a cascading false exit-1 right after
# the merge succeeded. Defining at file scope guarantees both paths can call it.
TEMP_FILES=()
cleanup_temp_files() {
  # macOS /bin/bash is 3.2.57; "${arr[@]}" on an empty array trips set -u
  # ("TEMP_FILES[@]: unbound variable"). The "${arr[@]+...}" idiom expands
  # to nothing when the array is empty/unset and to the array contents
  # otherwise — bash 3.2-safe.
  for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
}

print_status() {
  echo -e "${BLUE}$1${NC}"
}

# Verbose-aware output (requires RITE_VERBOSE=true or --supervised)
source "$RITE_LIB_DIR/utils/logging.sh"

# Helper: Add or update "Last Updated" timestamp in documentation
update_doc_timestamp() {
  local doc_path="$1"
  local today=$(date +%Y-%m-%d)

  if [ ! -f "$doc_path" ]; then
    return 1
  fi

  # Check if doc already has timestamp
  if grep -q "^> \*\*Last Updated:\*\*" "$doc_path"; then
    # Update existing timestamp
    sed -i.bak "s/^> \*\*Last Updated:\*\*.*/> **Last Updated:** $today (automated cleanup)/" "$doc_path"
    rm -f "${doc_path}.bak"
    print_success "Updated timestamp in $(basename "$doc_path")"
  elif grep -q "^Last Updated:" "$doc_path"; then
    # Update alternative format
    sed -i.bak "s/^Last Updated:.*/Last Updated: $today/" "$doc_path"
    rm -f "${doc_path}.bak"
    print_success "Updated timestamp in $(basename "$doc_path")"
  else
    # Add new timestamp after first header
    awk -v date="$today" '
      /^# / && !timestamp_added {
        print
        print ""
        print "> **Last Updated:** " date " (automated cleanup)"
        print ""
        timestamp_added = 1
        next
      }
      { print }
    ' "$doc_path" > "${doc_path}.tmp"
    mv "${doc_path}.tmp" "$doc_path"
    print_success "Added timestamp to $(basename "$doc_path")"
  fi
}

# Update Security Development Guide from PR review findings
update_security_guide_from_pr() {
  local pr_number=$1
  local security_guide="docs/security/DEVELOPMENT-GUIDE.md"

  # Check if auto-update is disabled via env var
  if [ "${SECURITY_GUIDE_AUTO_UPDATE:-true}" = "false" ]; then
    print_info "Security guide auto-update disabled (SECURITY_GUIDE_AUTO_UPDATE=false)"
    return 0
  fi

  # Validate PR number is numeric
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    print_error "Invalid PR number: $pr_number"
    return 1
  fi

  # Check if security guide exists
  if [ ! -f "$security_guide" ]; then
    return 0
  fi

  # Check file size (skip if over 500KB to avoid API issues)
  GUIDE_SIZE=$(wc -c < "$security_guide")
  MAX_SIZE=512000  # 500KB
  if [ "$GUIDE_SIZE" -gt "$MAX_SIZE" ]; then
    print_warning "Security guide too large ($((GUIDE_SIZE / 1024))KB), skipping auto-update"
    return 0
  fi

  print_status "Checking for security findings in PR #$pr_number..."

  # Extract Claude review comments (check multiple possible bot names)
  REVIEW_COMMENTS=$(gh_safe pr view "$pr_number" --json comments --jq '.comments[] | select(.author.login | test("claude"; "i")) | .body')

  if [ -z "$REVIEW_COMMENTS" ]; then
    return 0
  fi

  # Check if comments contain security findings by parsing structured Findings line
  # Review format: "Findings: [CRITICAL: N | HIGH: N | MEDIUM: N | LOW: N]"
  # Parse the structured summary instead of bare-word matching (avoids false positives
  # from reasoning text like "no critical issues found")
  FINDINGS_LINE=$(echo "$REVIEW_COMMENTS" | grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+" | head -1 || true)

  if [ -z "$FINDINGS_LINE" ]; then
    print_info "No findings summary detected in review"
    return 0
  fi

  # Extract severity counts from structured line
  CRITICAL_NUM=$(echo "$FINDINGS_LINE" | grep -oE "CRITICAL: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  HIGH_NUM=$(echo "$FINDINGS_LINE" | grep -oE "HIGH: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  MEDIUM_NUM=$(echo "$FINDINGS_LINE" | grep -oE "MEDIUM: [0-9]+" | grep -oE "[0-9]+" || echo "0")

  # Sum severity counts to check if any security findings exist
  SEVERITY_SUM=$((CRITICAL_NUM + HIGH_NUM + MEDIUM_NUM))

  if [ "$SEVERITY_SUM" -eq 0 ]; then
    print_info "No security findings detected in review (all severities: 0)"
    return 0
  fi

  print_warning "Security findings detected in PR #$pr_number"
  print_status "Analyzing findings against existing security guide..."

  # Use provider to analyze and update guide
  if ! provider_detect_cli 2>/dev/null; then
    print_warning "Provider CLI not found, skipping auto-update"
    return 0
  fi

  # cleanup_temp_files and TEMP_FILES are defined at file scope (see top of
  # file) so the EXIT trap in the main body can call them too.
  trap cleanup_temp_files EXIT ERR INT TERM

  # Create analysis prompt using temp files (avoid command injection)
  ANALYSIS_TEMP=$(mktemp)
  TEMP_FILES+=("$ANALYSIS_TEMP")
  cat > "$ANALYSIS_TEMP" << 'ANALYSIS_EOF'
Analyze these security findings from PR #$PR_NUMBER against the existing Security Development Guide.

PR REVIEW FINDINGS:
ANALYSIS_EOF
  echo "$REVIEW_COMMENTS" >> "$ANALYSIS_TEMP"
  cat >> "$ANALYSIS_TEMP" << 'ANALYSIS_EOF'

EXISTING SECURITY GUIDE:
ANALYSIS_EOF
  cat "$security_guide" >> "$ANALYSIS_TEMP"
  cat >> "$ANALYSIS_TEMP" << 'ANALYSIS_EOF'

For each CRITICAL, HIGH, or MEDIUM security issue found in the PR review:

1. Determine if this is a NEW issue or similar to existing guide entry
2. If NEW: Identify which category it belongs to and provide the new entry text
3. If EXISTING: Identify which entry to update and how to expand its scope

Format your response as actionable updates:

### NEW: [Category Name] > [Subcategory]
[Full markdown entry to add, including occurrences, examples, etc.]

### UPDATE: [Existing entry title]
Add to occurrences: PR #$PR_NUMBER: [file:line] - [context]
Update example section: [any new code examples to add]

Keep it precise and actionable. Only include security issues that need documentation.
ANALYSIS_EOF

  # Call Claude Code for analysis
  CLAUDE_ERROR=$(mktemp)
  TEMP_FILES+=("$CLAUDE_ERROR")
  _uncached_exit=0
  SECURITY_ANALYSIS=$(provider_run_uncached "$(cat "$ANALYSIS_TEMP")" "$CLAUDE_ERROR") || _uncached_exit=$?

  if [ "${_uncached_exit}" -eq 124 ]; then
    print_warning "Claude call timed out after ${RITE_CLAUDE_TIMEOUT_AGENTIC:-1800}s — retrying or aborting"
    print_warning "Claude analysis timed out, skipping auto-update"
    return 0
  fi

  if [ -s "$CLAUDE_ERROR" ]; then
    print_warning "$(provider_name) error: $(cat "$CLAUDE_ERROR" | head -1)"
  fi

  if [ -z "$SECURITY_ANALYSIS" ]; then
    print_warning "Claude analysis failed, skipping auto-update"
    return 0
  fi

  # Check if Claude found actionable updates
  if ! echo "$SECURITY_ANALYSIS" | grep -qE "^### (NEW|UPDATE):"; then
    print_info "No actionable security guide updates identified"
    return 0
  fi

  print_success "Security guide analysis complete"

  # Apply updates using Sharkrite
  print_status "Applying updates to security guide..."

  # Use temp files to avoid command injection
  UPDATE_TEMP=$(mktemp)
  TEMP_FILES+=("$UPDATE_TEMP")
  cat > "$UPDATE_TEMP" << 'UPDATE_EOF'
Apply these security guide updates to the document:

UPDATES TO APPLY:
UPDATE_EOF
  echo "$SECURITY_ANALYSIS" >> "$UPDATE_TEMP"
  cat >> "$UPDATE_TEMP" << 'UPDATE_EOF'

CURRENT SECURITY GUIDE:
UPDATE_EOF
  cat "$security_guide" >> "$UPDATE_TEMP"
  cat >> "$UPDATE_TEMP" << UPDATE_EOF

Generate the COMPLETE updated security guide with:
1. NEW entries added to appropriate categories
2. EXISTING entries updated with new occurrences
3. Updated timestamp: $(date +%Y-%m-%d) (PR #$pr_number)
4. Updated total issues count

Return ONLY the complete updated markdown file, nothing else.
UPDATE_EOF

  CLAUDE_ERROR2=$(mktemp)
  TEMP_FILES+=("$CLAUDE_ERROR2")
  _uncached_exit2=0
  UPDATED_GUIDE=$(provider_run_uncached "$(cat "$UPDATE_TEMP")" "$CLAUDE_ERROR2") || _uncached_exit2=$?

  if [ "${_uncached_exit2}" -eq 124 ]; then
    print_warning "Claude call timed out after ${RITE_CLAUDE_TIMEOUT_AGENTIC:-1800}s — retrying or aborting"
    print_warning "Auto-update timed out, saving analysis for manual review"
    echo "$SECURITY_ANALYSIS" > /tmp/security-guide-updates-pr${pr_number}.txt
    print_info "Analysis saved to: /tmp/security-guide-updates-pr${pr_number}.txt"
    return 0
  fi

  if [ -s "$CLAUDE_ERROR2" ]; then
    print_warning "$(provider_name) error: $(cat "$CLAUDE_ERROR2" | head -1)"
  fi

  if [ -z "$UPDATED_GUIDE" ]; then
    print_warning "Auto-update failed, saving analysis for manual review"
    echo "$SECURITY_ANALYSIS" > /tmp/security-guide-updates-pr${pr_number}.txt
    print_info "Analysis saved to: /tmp/security-guide-updates-pr${pr_number}.txt"
    return 0
  fi

  # Backup current guide
  BACKUP_FILE="${security_guide}.backup-$(date +%s)"
  cp "$security_guide" "$BACKUP_FILE"

  # Cleanup old backups (keep last 5)
  BACKUP_DIR=$(dirname "$security_guide")
  # shellcheck disable=SC2012
  ls -t "$BACKUP_DIR"/DEVELOPMENT-GUIDE.md.backup-* 2>/dev/null \
    | tail -n +6 | while IFS= read -r _old_backup; do rm -f "$_old_backup"; done || true

  # Store original size for validation
  ORIGINAL_SIZE=$(wc -l < "$security_guide")

  # Apply the updated guide
  echo "$UPDATED_GUIDE" > "$security_guide"

  # Verify the update looks reasonable (must be at least 80% of original size)
  # Using 80% threshold to detect truncation while allowing growth
  NEW_SIZE=$(wc -l < "$security_guide")
  MIN_SIZE=$((ORIGINAL_SIZE * 80 / 100))
  if [ "$NEW_SIZE" -lt "$MIN_SIZE" ]; then
    print_error "Updated guide too short ($NEW_SIZE lines vs $ORIGINAL_SIZE original), restoring backup"
    mv "$BACKUP_FILE" "$security_guide"
    return 1
  fi

  git add "$security_guide"
  git commit -m "docs: update security guide from PR #$pr_number findings" 2>/dev/null && \
    print_success "Security guide updated and committed" || \
    print_warning "No changes to commit"

  # Display summary
  echo ""
  print_success "Added/updated entries from PR review:"
  echo "$SECURITY_ANALYSIS" | grep -E "^###" | head -10
  echo ""
}

# If no PR number provided, try to find PR for current branch
if [ -z "$PR_NUMBER" ]; then
  print_info "No PR number provided, searching for PR on branch: $CURRENT_BRANCH"

  PR_JSON=$(gh_safe pr list --head "$CURRENT_BRANCH" --json number,title,url --jq '.[0]')

  if [ -z "$PR_JSON" ] || [ "$PR_JSON" = "null" ]; then
    print_error "No PR found for branch: $CURRENT_BRANCH"
    echo ""
    echo "Usage:"
    echo "  rite merge <pr-number>  # Merge specific PR"
    echo "  rite merge              # Merge PR for current branch (must have existing PR)"
    exit 1
  fi

  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
  print_success "Found PR #$PR_NUMBER for branch $CURRENT_BRANCH"
fi

verbose_header "🔍 PR Merge Workflow - PR #$PR_NUMBER"

# Fetch PR details
verbose_status "Fetching PR details..."
PR_DETAILS=$(gh_safe pr view "$PR_NUMBER" --json number,title,state,isDraft,mergeable,url,baseRefName,headRefName,statusCheckRollup)

if [ -z "$PR_DETAILS" ]; then
  print_error "Could not fetch PR #$PR_NUMBER"
  exit 1
fi

# Extract PR information
PR_TITLE=$(echo "$PR_DETAILS" | jq -r '.title')
PR_STATE=$(echo "$PR_DETAILS" | jq -r '.state')
PR_IS_DRAFT=$(echo "$PR_DETAILS" | jq -r '.isDraft')
PR_MERGEABLE=$(echo "$PR_DETAILS" | jq -r '.mergeable')
PR_URL=$(echo "$PR_DETAILS" | jq -r '.url')
PR_BASE=$(echo "$PR_DETAILS" | jq -r '.baseRefName')
PR_HEAD=$(echo "$PR_DETAILS" | jq -r '.headRefName' || true)

if is_verbose; then
  print_header "📋 PR Information"
  echo "Title: $PR_TITLE"
  echo "Number: #$PR_NUMBER"
  echo "URL: $PR_URL"
  echo "State: $PR_STATE"
  echo "Base: $PR_BASE → Head: $PR_HEAD"
  echo "Draft: $PR_IS_DRAFT"
  echo "Mergeable: $PR_MERGEABLE"
fi

# Validation checks
print_header "🔍 Pre-Merge Validation"

VALIDATION_FAILED=false

# Check 1: PR must be open
if [ "$PR_STATE" != "OPEN" ]; then
  print_error "PR is not open (state: $PR_STATE)"
  VALIDATION_FAILED=true
else
  verbose_success "PR is open"
fi

# Check 2: PR must not be a draft (only show error, not success - it's expected)
if [ "$PR_IS_DRAFT" = "true" ]; then
  print_error "PR is still in draft state"
  VALIDATION_FAILED=true
fi

# Check 3: PR must be mergeable
# GitHub computes mergeability lazily — UNKNOWN means not computed yet. Retry a few times.
if [ "$PR_MERGEABLE" = "UNKNOWN" ]; then
  print_status "Waiting for GitHub to compute mergeability..."
  for _i in 1 2 3; do
    sleep 3
    PR_MERGEABLE=$(gh_safe pr view "$PR_NUMBER" --json mergeable --jq '.mergeable')
    PR_MERGEABLE="${PR_MERGEABLE:-UNKNOWN}"
    [ "$PR_MERGEABLE" != "UNKNOWN" ] && break
  done
fi

if [ "$PR_MERGEABLE" != "MERGEABLE" ]; then
  print_warning "PR mergeable state: $PR_MERGEABLE"
  if [ "$PR_MERGEABLE" = "CONFLICTING" ]; then
    # Always attempt to auto-resolve by merging main into the feature branch
    print_info "Attempting to merge main into feature branch to resolve conflicts..."
    # Fetch with retries — reading origin/main immediately after; stale data = wrong conflict state
    if ! git_fetch_safe origin main; then
      print_error "Cannot resolve conflicts: failed to fetch fresh main ref"
      VALIDATION_FAILED=true
    elif git merge origin/main --no-edit 2>/dev/null; then
      if git push origin "$PR_HEAD" 2>/dev/null; then
        print_success "Merged main into branch and pushed — re-checking mergeable state"
        # Give GitHub a moment to update mergeable state
        sleep 3
        PR_MERGEABLE=$(gh_safe pr view "$PR_NUMBER" --json mergeable --jq '.mergeable')
        PR_MERGEABLE="${PR_MERGEABLE:-UNKNOWN}"
        if [ "$PR_MERGEABLE" = "MERGEABLE" ]; then
          print_success "PR is now mergeable"
        else
          print_error "PR still not mergeable after merging main (state: $PR_MERGEABLE)"
          VALIDATION_FAILED=true
        fi
      else
        print_error "Push failed after merging main"
        git reset --hard HEAD~1 2>/dev/null || true
        VALIDATION_FAILED=true
      fi
    else
      git merge --abort 2>/dev/null || true
      print_error "PR has merge conflicts that could not be auto-resolved"
      VALIDATION_FAILED=true
    fi
  else
    print_info "Mergeable state is uncertain, will attempt merge anyway"
  fi
else
  verbose_success "PR is mergeable"
fi

# Check 4: Status checks
echo ""
echo -e "${BLUE}📋 Status Checks${NC}"
STATUS_CHECKS=$(echo "$PR_DETAILS" | jq -r '.statusCheckRollup // []')
REQUIRED_CHECKS=$(echo "$STATUS_CHECKS" | jq -r '[.[] | select(.isRequired == true)]')
REQUIRED_CHECKS_COUNT=$(echo "$REQUIRED_CHECKS" | jq 'length')

if [ "$REQUIRED_CHECKS_COUNT" -gt 0 ]; then
  echo "  Required: $REQUIRED_CHECKS_COUNT"

  echo "$REQUIRED_CHECKS" | jq -r '.[] | "  - \(.name): \(.conclusion // .status)"' | while read line; do
    if echo "$line" | grep -q "SUCCESS"; then
      echo -e "  ${GREEN}✓${NC} $(echo $line | sed 's/: SUCCESS//')"
    elif echo "$line" | grep -q "FAILURE\|ERROR"; then
      echo -e "  ${RED}✗${NC} $(echo $line | sed 's/: FAILURE//' | sed 's/: ERROR//')"
    else
      echo -e "  ${YELLOW}⏳${NC} $line"
    fi
  done

  # Check for failures
  FAILED_CHECKS=$(echo "$REQUIRED_CHECKS" | jq -r '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  PENDING_CHECKS=$(echo "$REQUIRED_CHECKS" | jq -r '[.[] | select(.conclusion == null or .conclusion == "PENDING")] | length')

  if [ "$FAILED_CHECKS" -gt 0 ]; then
    print_error "$FAILED_CHECKS required check(s) failed"
    VALIDATION_FAILED=true
  elif [ "$PENDING_CHECKS" -gt 0 ]; then
    print_warning "$PENDING_CHECKS required check(s) still pending"
  else
    print_success "All required checks passed"
  fi
else
  echo "  None configured"
fi

# Check 5: Sharkrite code review (via PR comments or formal reviews)
echo ""
echo -e "${BLUE}🦈 Sharkrite Review${NC}"
CLAUDE_REVIEW_FOUND=false

# First check formal reviews for Sharkrite marker
_JQ_FORMAL_REVIEW="[.reviews[] | select(.body | contains(\"${RITE_MARKER_REVIEW}\") or contains(\"Claude Code Review\"))] | .[-1] | .body"
LATEST_CLAUDE_REVIEW=$(gh_safe pr view "$PR_NUMBER" --json reviews \
  --jq "$_JQ_FORMAL_REVIEW")

# If not in formal reviews, check PR comments for Sharkrite marker
if [ -z "$LATEST_CLAUDE_REVIEW" ] || [ "$LATEST_CLAUDE_REVIEW" = "null" ]; then
  _JQ_COMMENT_REVIEW="[.comments[] | select(.body | contains(\"${RITE_MARKER_REVIEW}\") or contains(\"Claude Code Review\"))] | .[-1] | .body"
  LATEST_CLAUDE_REVIEW=$(gh_safe pr view "$PR_NUMBER" --json comments \
    --jq "$_JQ_COMMENT_REVIEW")
fi

if [ -n "$LATEST_CLAUDE_REVIEW" ] && [ "$LATEST_CLAUDE_REVIEW" != "null" ]; then
  CLAUDE_REVIEW_FOUND=true

  # Parse CRITICAL count using multiple patterns (case-insensitive, flexible format)
  CRITICAL_COUNT=$(echo "$LATEST_CLAUDE_REVIEW" | grep -oiE '(CRITICAL|critical)[[:space:]:]+\(?[0-9]+\)?' | grep -oE '[0-9]+' | head -1 || true)

  if [ -z "$CRITICAL_COUNT" ]; then
    # Fallback: check for "### ❌ CRITICAL" sections with actual content
    if echo "$LATEST_CLAUDE_REVIEW" | grep -q "### ❌ CRITICAL"; then
      CRITICAL_SECTION=$(echo "$LATEST_CLAUDE_REVIEW" | sed -n '/### ❌ CRITICAL/,/###/p' || true)
      if echo "$CRITICAL_SECTION" | grep -q "#### "; then
        CRITICAL_COUNT=1
      else
        CRITICAL_COUNT=0
      fi
    else
      CRITICAL_COUNT=0
    fi
  fi

  # Check for overall assessment verdict
  REVIEW_VERDICT=$(echo "$LATEST_CLAUDE_REVIEW" | grep -oiE "Overall Assessment:.*?(APPROVE|NEEDS WORK)" | head -1 || echo "")

  if [ "$CRITICAL_COUNT" -gt 0 ]; then
    # Check if the assessment already resolved/dismissed all CRITICAL items.
    # The review shows raw findings; the assessment is the authoritative verdict.
    _JQ_ASSESSMENT_BODY="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].body // \"\""
    ASSESSMENT_ACTIONABLE=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_JQ_ASSESSMENT_BODY" | grep -c "^### .* - ACTIONABLE_NOW" || true)

    if [ "${ASSESSMENT_ACTIONABLE:-0}" -eq 0 ]; then
      # Assessment exists and has 0 ACTIONABLE_NOW — CRITICALs were resolved or dismissed
      print_success "Review has $CRITICAL_COUNT CRITICAL finding(s) but assessment resolved all — OK to merge"
    else
      print_error "Found $CRITICAL_COUNT CRITICAL issue(s) - must be addressed"
      VALIDATION_FAILED=true
    fi
  elif echo "$REVIEW_VERDICT" | grep -qi "APPROVE"; then
    print_success "Review passed (APPROVE)"
  elif echo "$REVIEW_VERDICT" | grep -qi "NEEDS WORK"; then
    print_warning "Review verdict: NEEDS WORK"
  else
    print_success "Review passed (CRITICAL: 0)"
  fi
else
  echo "  Not found"
fi

# HIGH/MEDIUM issues are already handled by Phase 3 (assess-and-resolve.sh).
# ACTIONABLE_NOW items are fixed in the fix loop; ACTIONABLE_LATER items become
# follow-up issues. No need to re-assess here at merge time.

# Summary of validation
echo ""
if [ "$VALIDATION_FAILED" = true ]; then
  print_header "❌ Validation Failed"
  echo "The following issues must be resolved before merging:"
  echo ""
  echo "Please address the errors above and try again."
  echo ""
  echo "To view PR details:"
  echo "  gh pr view $PR_NUMBER --web"
  exit 1
fi

print_header "✅ All Validations Passed"
echo "  • PR state: open, not draft, mergeable"
echo "  • Status checks: ${REQUIRED_CHECKS_COUNT:-0} required (all passed)"
echo "  • Sharkrite review: $([ "$CLAUDE_REVIEW_FOUND" = true ] && echo "passed" || echo "not required")"
echo ""

# Documentation assessment runs post-merge (see below) to avoid blocking the merge.
# Internal docs (.rite/docs/) are gitignored in target projects, and Layer 2 user
# doc updates commit separately — neither needs to land on the feature branch.
DOC_ASSESSMENT_SCRIPT="$RITE_LIB_DIR/core/assess-documentation.sh"

# Check for security findings and update guide (part of documentation phase)
update_security_guide_from_pr "$PR_NUMBER"

# Confirm merge
if [ "$AUTO_MODE" = false ]; then
  echo ""
  echo "Ready to merge PR #$PR_NUMBER:"
  echo "  $PR_TITLE"
  echo ""
  read -p "Proceed with merge? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Merge cancelled"
    exit 1
  fi

  MERGE_STRATEGY=1
else
  MERGE_STRATEGY=1
fi

print_header "🔀 Merge & Cleanup"

case $MERGE_STRATEGY in
  1)
    MERGE_METHOD="squash"
    echo "Using squash merge (recommended)"
    ;;
  2)
    MERGE_METHOD="merge"
    echo "Using merge commit"
    ;;
  3)
    MERGE_METHOD="rebase"
    echo "Using rebase merge"
    ;;
  *)
    print_warning "Invalid choice, defaulting to squash"
    MERGE_METHOD="squash"
    ;;
esac

# Perform merge
verbose_header "🚀 Merging PR #$PR_NUMBER"

# Atomic merge with SHA verification: use the GitHub API merge endpoint with the
# sha parameter to reject the merge if the PR head changed since we last checked.
# This prevents foreign commits from being silently merged between assessment and merge.
EXPECTED_HEAD=$(gh_safe pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')
REPO_NAME=$(gh_safe repo view --json nameWithOwner --jq '.nameWithOwner')

_do_merge() {
  # Attempt merge and capture output + exit code, immune to set -e.
  # Usage: _do_merge <cmd...>
  # Sets MERGE_OUTPUT and MERGE_EXIT_CODE in the caller's scope.
  #
  # CONTRACT (gh_safe stderr coupling):
  # This function uses 2>&1 to merge stderr into MERGE_OUTPUT. The 409 "Head
  # branch was modified" detection on line ~707 relies on gh_safe echoing
  # GitHub's error text to its own stderr on the non-transient path
  # (gh-retry.sh: `echo "$stderr_content" >&2`). The 2>&1 here captures that
  # stderr into MERGE_OUTPUT, making it grep-able.
  #
  # RISK: If gh_safe's non-transient error path is changed to suppress stderr
  # (e.g., redirect to a file instead of >&2, or gate on a verbosity flag),
  # the 409 grep below silently stops matching and SHA-mismatch recovery
  # stops working with no visible error.
  #
  # Regression test: tests/regression/merge-pr-sha-mismatch-detection.bats
  MERGE_OUTPUT=$("$@" 2>&1) && MERGE_EXIT_CODE=0 || MERGE_EXIT_CODE=$?
}

if [ -n "$EXPECTED_HEAD" ] && [ -n "$REPO_NAME" ]; then
  # Use API merge for atomic head verification
  _do_merge gh_safe api "repos/$REPO_NAME/pulls/$PR_NUMBER/merge" \
    -X PUT \
    -f merge_method="$MERGE_METHOD" \
    -f sha="$EXPECTED_HEAD"

  # Check for SHA mismatch (API returns error when head changed)
  if [ $MERGE_EXIT_CODE -ne 0 ] && echo "$MERGE_OUTPUT" | grep -qiE "Head branch was modified|409"; then
    print_error "PR head changed during merge — someone pushed commits after assessment"
    print_info "Expected HEAD: ${EXPECTED_HEAD:0:12}"

    # Attempt divergence recovery
    source "$RITE_LIB_DIR/utils/divergence-handler.sh"
    DIV_BRANCH="$PR_HEAD"
    if detect_divergence "$DIV_BRANCH"; then
      DIV_RESULT=0
      handle_push_divergence "$DIV_BRANCH" "${ISSUE_NUMBER:-}" "$PR_NUMBER" "$AUTO_MODE" || DIV_RESULT=$?

      if [ $DIV_RESULT -eq 0 ]; then
        # Divergence resolved — retry the merge with updated head
        EXPECTED_HEAD=$(gh_safe pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')
        _do_merge gh_safe api "repos/$REPO_NAME/pulls/$PR_NUMBER/merge" \
          -X PUT \
          -f merge_method="$MERGE_METHOD" \
          -f sha="$EXPECTED_HEAD"
      elif [ $DIV_RESULT -eq 5 ]; then
        # Usage cap reached — propagate so batch can abort cleanly
        print_error "Claude usage cap reached during merge-time divergence resolution — aborting batch"
        MERGE_EXIT_CODE=5
      else
        print_error "Could not resolve divergence at merge time"
        MERGE_EXIT_CODE=1
      fi
    fi
  fi

  # Handle "not mergeable" — branch may be behind main; try updating and retry once
  if [ $MERGE_EXIT_CODE -ne 0 ] && echo "$MERGE_OUTPUT" | grep -qiE "not mergeable|405"; then
    print_warning "PR is not mergeable — attempting branch update against main"
    # Fetch with retries — reading origin/main immediately after; stale data = wrong merge base
    if ! git_fetch_safe origin main; then
      print_error "Cannot update branch: failed to fetch fresh main ref"
    elif git merge origin/main --no-edit 2>/dev/null && git push origin "$PR_HEAD" 2>/dev/null; then
      print_status "Branch updated — retrying merge..."
      sleep 3
      EXPECTED_HEAD=$(gh_safe pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')
      _do_merge gh_safe api "repos/$REPO_NAME/pulls/$PR_NUMBER/merge" \
        -X PUT \
        -f merge_method="$MERGE_METHOD" \
        -f sha="$EXPECTED_HEAD"
    else
      git merge --abort 2>/dev/null || true
      print_error "Could not update branch against main"
    fi
  fi
else
  # Fallback: gh pr merge (no SHA verification available)
  print_info "Using fallback merge (no SHA verification)"
  _do_merge gh_safe pr merge "$PR_NUMBER" "--$MERGE_METHOD"

  # Handle "not mergeable" in fallback path — branch may be behind main
  if [ $MERGE_EXIT_CODE -ne 0 ] && echo "$MERGE_OUTPUT" | grep -qiE "not mergeable"; then
    print_warning "PR is not mergeable — attempting branch update against main"
    # Fetch with retries — reading origin/main immediately after; stale data = wrong merge base
    if ! git_fetch_safe origin main; then
      print_error "Cannot update branch: failed to fetch fresh main ref"
    elif git merge origin/main --no-edit 2>/dev/null && git push origin "$PR_HEAD" 2>/dev/null; then
      print_status "Branch updated — retrying merge..."
      sleep 3
      _do_merge gh_safe pr merge "$PR_NUMBER" "--$MERGE_METHOD"
    else
      git merge --abort 2>/dev/null || true
      print_error "Could not update branch against main"
    fi
  fi
fi

if [ $MERGE_EXIT_CODE -eq 5 ]; then
  # Usage cap reached during divergence resolution — propagate exit 5 for batch abort
  exit 5
elif [ $MERGE_EXIT_CODE -eq 0 ]; then
  verbose_header "✅ PR Merged Successfully"

  print_success "PR #$PR_NUMBER merged into $PR_BASE"

  # Merge succeeded — now run cleanup phase. If cleanup crashes, exit with code 6
  # (not code 1) so batch reporter can distinguish "merge failed" from "merge succeeded
  # but cleanup failed". Turn off set -e so cleanup errors don't immediately exit.
  set +e
  CLEANUP_FAILED=false

  # Note: We don't use a broad ERR trap because many cleanup operations intentionally
  # handle errors (e.g., "git branch -D foo 2>/dev/null || true"). Instead, we check
  # exit codes at critical points where a failure genuinely indicates cleanup broke.

  # Start doc assessment in the background (runs concurrently with tech-debt, cleanup)
  _DOC_PID=""
  _DOC_LOG=$(mktemp)
  if [ -f "$DOC_ASSESSMENT_SCRIPT" ]; then
    if [ "$AUTO_MODE" = true ]; then
      "$DOC_ASSESSMENT_SCRIPT" "$PR_NUMBER" --auto > "$_DOC_LOG" 2>&1 &
    else
      "$DOC_ASSESSMENT_SCRIPT" "$PR_NUMBER" > "$_DOC_LOG" 2>&1 &
    fi
    _DOC_PID=$!
  fi

  # Create tech-debt issues from encountered issues BEFORE clearing scratchpad
  if type create_tech_debt_issues &>/dev/null; then
    _debt_exit=0
    DEBT_COUNT=$(create_tech_debt_issues "$PR_NUMBER") || _debt_exit=$?
    if [ $_debt_exit -ne 0 ]; then
      print_warning "Tech-debt issue creation failed (exit $_debt_exit)"
      CLEANUP_FAILED=true
      DEBT_COUNT=0  # Initialize to prevent empty string in comparison
    elif [ "$DEBT_COUNT" -gt 0 ]; then
      print_success "Created $DEBT_COUNT tech-debt issue(s)"
    fi
    # Clear encountered issues after processing
    if type clear_encountered_issues &>/dev/null; then
      clear_encountered_issues || true  # Best-effort, not critical
    fi
  fi

  # Clear "Current Work" section in scratchpad (merge complete)
  if type clear_current_work &>/dev/null; then
    clear_current_work
  fi

  # Update scratchpad with security findings (BEFORE clearing context)
  if type update_scratchpad_from_pr &>/dev/null; then
    PR_TITLE=$(gh_safe pr view "$PR_NUMBER" --json title --jq '.title')
    PR_TITLE="${PR_TITLE:-PR #$PR_NUMBER}"
    update_scratchpad_from_pr "$PR_NUMBER" "$PR_TITLE"
  fi

  # Extract issue number from PR if it exists
  ISSUE_NUMBER=$(gh_safe pr view "$PR_NUMBER" --json body --jq '.body' | sed -n 's/.*Closes #\([0-9]\+\).*/\1/p' | head -1 || true)

  if [ ! -z "$ISSUE_NUMBER" ]; then
    if [ "$AUTO_MODE" = false ]; then
      print_info "This PR closes issue #$ISSUE_NUMBER"
      echo ""
      read -p "Close linked issue #$ISSUE_NUMBER? (y/n) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        gh_safe issue close "$ISSUE_NUMBER" --comment "Closed by PR #$PR_NUMBER" 2>/dev/null || true
        print_success "Issue #$ISSUE_NUMBER closed"
      fi
    else
      # Auto mode: automatically close linked issue
      print_info "Auto mode: closing linked issue #$ISSUE_NUMBER"
      gh_safe issue close "$ISSUE_NUMBER" --comment "Closed by PR #$PR_NUMBER" 2>/dev/null || true
      print_success "Issue #$ISSUE_NUMBER closed"
    fi
  fi

  # Check for follow-up issues (now created during assessment phase)
  echo ""
  echo -e "${BLUE}📋 Follow-up Issues${NC}"

  # Find follow-up issues via the machine-readable marker that assess-and-resolve.sh
  # adds as a PR comment: <!-- sharkrite-followup-issue:N -->
  # This is more reliable than scanning the PR body for #N patterns, which
  # matches the linked issue itself (Closes #N) and random references.
  ASSESSMENT_ISSUES=$(gh_safe pr view "$PR_NUMBER" --json comments --jq '.comments[].body' | grep -oE "${RITE_MARKER_FOLLOWUP}:([0-9]+)" | grep -oE '[0-9]+' | sort -u || true)

  if [ -n "$ASSESSMENT_ISSUES" ]; then
    ISSUE_COUNT=$(echo "$ASSESSMENT_ISSUES" | wc -l | tr -d ' ')
    print_success "Assessment created $ISSUE_COUNT follow-up issue(s)"
    echo "  Issues: $(echo $ASSESSMENT_ISSUES | sed 's/^/#/' | tr '\n' ' ')"

    # Send Slack notification with merge summary
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
      ISSUES_LIST=""
      for issue_num in $ASSESSMENT_ISSUES; do
        ISSUE_TITLE=$(gh_safe issue view "$issue_num" --json title --jq '.title')
        ISSUE_TITLE="${ISSUE_TITLE:-Issue #$issue_num}"
        REPO_URL=$(gh_safe repo view --json url --jq '.url')
        ISSUES_LIST="${ISSUES_LIST}• <${REPO_URL}/issues/${issue_num}|#${issue_num}>: ${ISSUE_TITLE}\n"
      done

      MERGE_NOTIFICATION="🎯 *PR #${PR_NUMBER} Merged Successfully*

✅ ${PR_TITLE}

📋 *Follow-up Issues* (${ISSUE_COUNT}):
${ISSUES_LIST}
🔗 *PR Link*: <${PR_URL}|View PR #${PR_NUMBER}>"

      # sharkrite-lint disable UNQUOTED_HEREDOC - Intentional: variables must be expanded
      SLACK_PAYLOAD=$(cat <<EOF
{
  "text": "PR #${PR_NUMBER} Merged",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "$MERGE_NOTIFICATION"
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "Repository: \`${RITE_PROJECT_NAME}\` | Branch: \`${PR_HEAD}\` → \`${PR_BASE}\`"
        }
      ]
    }
  ]
}
EOF
)

      HTTP_CODE=$(curl -X POST "$SLACK_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$SLACK_PAYLOAD" \
        -w "%{http_code}" \
        -s -o /dev/null 2>/dev/null || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        print_success "Slack notification sent"
      else
        print_warning "Slack notification failed (HTTP $HTTP_CODE)"
      fi
    fi
  else
    echo "  None (all items addressed in PR)"
  fi

  # ─── Cleanup: branches + worktree ───
  echo ""
  print_status "Cleaning up..."
  sleep 2  # Give GitHub a moment to process the merge

  # Delete remote branch
  if git ls-remote --heads origin "$PR_HEAD" 2>/dev/null | grep -q "$PR_HEAD"; then
    if git push origin --delete "$PR_HEAD" 2>/dev/null; then
      echo -e "${GREEN}  ✓ Deleted remote branch: origin/$PR_HEAD${NC}"
    else
      print_warning "Could not delete remote branch (may require permissions)"
    fi
  else
    print_info "Remote branch already deleted: origin/$PR_HEAD"
  fi

  if [ "${RITE_VERBOSE:-false}" = "true" ]; then
    echo ""
    print_info "Branch cleanup explained:"
    echo "   • Local branch: Lives on your machine only"
    echo "   • Remote branch: Lives on GitHub (origin/$PR_HEAD)"
    echo "   • Both are deleted after merge to keep repo clean"
    echo ""
  fi

  # Cleanup local branch if it exists
  if [ "$CURRENT_BRANCH" = "$PR_HEAD" ]; then
    if [ "$AUTO_MODE" = true ]; then
      # Auto mode: just delete the local branch. Don't try git checkout —
      # in a worktree, main is checked out elsewhere and checkout fails with
      # "fatal: 'main' is already used by worktree". The orchestrator handles
      # worktree removal separately.
      # Note: deletion may silently fail if branch is checked out in this worktree;
      # workflow-runner.sh will clean it up after removing the worktree.
      git branch -D $PR_HEAD 2>/dev/null || true
    else
      print_info "You are currently on the merged branch"
      echo ""
      read -p "Switch to $PR_BASE and delete local branch? (y/n) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        git checkout $PR_BASE 2>/dev/null || print_warning "Could not switch to $PR_BASE (may be checked out in another worktree)"
        git pull origin $PR_BASE 2>/dev/null || true
        git branch -D $PR_HEAD 2>/dev/null || true
        print_success "Switched to $PR_BASE and deleted local branch"
      fi
    fi
  elif git branch --list | grep -q "^  $PR_HEAD\$"; then
    if [ "$AUTO_MODE" = true ]; then
      # Branch exists but we're not on it — leftover from a worktree that was
      # already removed. Delete silently; no need to surface this to the user.
      git branch -D $PR_HEAD 2>/dev/null || true
    else
      print_info "Local branch $PR_HEAD still exists"
      echo ""
      read -p "Delete local branch? (y/n) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        git branch -D $PR_HEAD 2>/dev/null || true
        print_success "Local branch deleted"
      fi
    fi
  fi

  # Fast-forward local main to origin/main so the user's primary clone reflects
  # the merge. Without this, ls in the project root shows stale state and the
  # user (reasonably) concludes the work never landed.
  #
  # Two cases:
  #   1. main is checked out in some worktree (typical) — git pull --ff-only there
  #   2. main not checked out anywhere — git fetch origin main:main updates the ref directly
  MAIN_CHECKOUT_PATH=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / { p = substr($0, 10) } /^branch refs\/heads\/main$/ { print p; exit }' || true)
  if [ -n "$MAIN_CHECKOUT_PATH" ]; then
    if (cd "$MAIN_CHECKOUT_PATH" && git pull --ff-only origin main >/dev/null 2>&1); then
      print_success "Local main fast-forwarded to origin/main"
    else
      print_warning "Could not fast-forward local main in $MAIN_CHECKOUT_PATH — run 'git pull --ff-only' there manually"
    fi
  else
    if git fetch origin main:main >/dev/null 2>&1; then
      print_success "Local main fast-forwarded to origin/main"
    else
      print_warning "Could not update local main — run 'git pull --ff-only origin main' manually"
    fi
  fi

  # Pop stash if there are stashed changes (from claude-workflow.sh)
  if git stash list | grep -q "\[${RITE_MARKER_STASH}\]"; then
    print_status "Restoring stashed changes..."
    if git stash pop; then
      print_success "Stashed changes restored"
    else
      print_warning "Stash pop failed - you may need to resolve conflicts manually"
      echo "Run: git stash pop"
    fi
  fi

  # Cleanup worktree if running from one
  CURRENT_DIR=$(pwd)
  if git worktree list | grep -q "$CURRENT_DIR"; then
    MAIN_WORKTREE=$(git worktree list | head -1 | awk '{print $1}' || true)

    if [ "$CURRENT_DIR" != "$MAIN_WORKTREE" ]; then
      print_status "Cleaning up worktree..."

      # Move to main worktree FIRST — deep clean may remove stale worktrees
      # (including the current one), which invalidates our cwd
      cd "$MAIN_WORKTREE"

      # Clean up only this branch's notes from shared scratchpad
      if [ -f "$SCRATCHPAD_FILE" ]; then
        if [ "${RITE_VERBOSE:-false}" = "true" ]; then
          print_status "Cleaning up notes for branch: $PR_HEAD..."
        fi

        # Create backup before modification
        SCRATCHPAD_BACKUP="${SCRATCHPAD_FILE}.backup-$(date +%s)"
        cp "$SCRATCHPAD_FILE" "$SCRATCHPAD_BACKUP"

        # Acquire scratchpad lock via shared module (atomic PID write, hard timeout)
        # acquire_scratchpad_lock exits 1 on timeout — never proceeds without lock
        acquire_scratchpad_lock
        # Ensure the lock is released if the script exits unexpectedly between here
        # and the explicit release_scratchpad_lock call below (~line 1450).
        # Combine with cleanup_temp_files so we don't clobber the trap set at line 219,
        # and add INT/TERM so signals during the critical section also release the lock.
        trap 'release_scratchpad_lock; cleanup_temp_files' EXIT INT TERM

        # Create temp file for cleaned scratchpad
        TEMP_SCRATCH=$(mktemp)

        # Remove only sections tagged with this branch, keep everything else
        awk -v branch="$PR_HEAD" '
          # Track if we are inside this branchs section
          /^### Branch:/ {
            if ($3 == branch) {
              in_target_branch = 1
              next
            } else {
              in_target_branch = 0
            }
          }

          # Skip lines in target branch section until next ### or ##
          in_target_branch && /^###/ { in_target_branch = 0 }
          in_target_branch && /^##/ { in_target_branch = 0 }
          in_target_branch { next }

          # Print everything else
          { print }
        ' "$SCRATCHPAD_FILE" > "$TEMP_SCRATCH"

        # Add archive entry for this completed branch
        # Insert before "## Completed Work Archive" or at end
        if grep -q "^## Completed Work Archive" "$TEMP_SCRATCH"; then
          # Insert entry at top of archive section
          # sharkrite-lint disable UNQUOTED_HEREDOC - Intentional: variables must be expanded
          ARCHIVE_ENTRY=$(cat << EOF

### $(date +%Y-%m-%d): PR #$PR_NUMBER Merged
**Branch:** $PR_HEAD → $PR_BASE
**Title:** $(echo "$PR_TITLE" | head -c 80)
**Status:** Merged successfully

---
EOF
)
          # Insert after "## Completed Work Archive" header
          # Avoid awk -v with multiline value (BSD awk rejects embedded newlines)
          ARCHIVE_LINE=$(grep -n "^## Completed Work Archive" "$TEMP_SCRATCH" | head -1 | cut -d: -f1 || true)
          { head -n "$ARCHIVE_LINE" "$TEMP_SCRATCH"; echo "$ARCHIVE_ENTRY"; tail -n +"$((ARCHIVE_LINE + 1))" "$TEMP_SCRATCH"; } > "$TEMP_SCRATCH.2"
          mv "$TEMP_SCRATCH.2" "$TEMP_SCRATCH"
        else
          # Create archive section
          cat >> "$TEMP_SCRATCH" << EOF

---

## Completed Work Archive

### $(date +%Y-%m-%d): PR #$PR_NUMBER Merged
**Branch:** $PR_HEAD → $PR_BASE
**Title:** $(echo "$PR_TITLE" | head -c 80)
**Status:** Merged successfully

---

EOF
        fi

        # Replace scratchpad with cleaned version
        mv "$TEMP_SCRATCH" "$SCRATCHPAD_FILE"
        if [ "${RITE_VERBOSE:-false}" = "true" ]; then
          print_success "Scratchpad cleaned (removed notes for $PR_HEAD, kept other branches)"
        fi

        # Check if deep clean is needed (shared sections)
        SCRATCHPAD_SIZE=$(wc -c < "$SCRATCHPAD_FILE" 2>/dev/null || echo "0")
        LAST_DEEP_CLEAN=$(sed -n 's/.*<!-- last_deep_clean=\([0-9-]\+\).*/\1/p' "$SCRATCHPAD_FILE" 2>/dev/null | head -1 || echo "1970-01-01")
        DAYS_SINCE_CLEAN=$(( ( $(date +%s) - $(date -d "$LAST_DEEP_CLEAN" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$LAST_DEEP_CLEAN" +%s 2>/dev/null || echo 0) ) / 86400 ))

        SHOULD_DEEP_CLEAN=false
        DEEP_CLEAN_REASON=""

        # Check if there have been commits in last 2 weeks
        RECENT_COMMITS=$(git log --since="14 days ago" --oneline 2>/dev/null | wc -l)

        # Check conditions for deep clean
        if [ "$SCRATCHPAD_SIZE" -gt 51200 ]; then  # >50KB
          SHOULD_DEEP_CLEAN=true
          DEEP_CLEAN_REASON="scratchpad size ($(( SCRATCHPAD_SIZE / 1024 ))KB > 50KB)"
        elif [ "$DAYS_SINCE_CLEAN" -gt 14 ] && [ "$RECENT_COMMITS" -gt 0 ]; then  # >14 days + active development
          SHOULD_DEEP_CLEAN=true
          DEEP_CLEAN_REASON="last deep clean was $DAYS_SINCE_CLEAN days ago (${RECENT_COMMITS} commits in last 2 weeks)"
        elif [ "$DAYS_SINCE_CLEAN" -gt 14 ] && [ "$RECENT_COMMITS" -eq 0 ]; then
          print_info "Skipping deep clean: no commits in last 2 weeks (project idle)"
        fi

        if [ "$SHOULD_DEEP_CLEAN" = true ]; then
          echo ""
          print_warning "Deep clean triggered: $DEEP_CLEAN_REASON"
          print_status "Performing automated deep clean..."
          echo ""

          DEEP_CLEAN_TEMP=$(mktemp)
          TODAY=$(date +%Y-%m-%d)
          CUTOFF_30=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null)
          CUTOFF_60=$(date -d "60 days ago" +%Y-%m-%d 2>/dev/null || date -v-60d +%Y-%m-%d 2>/dev/null)
          CUTOFF_90=$(date -d "90 days ago" +%Y-%m-%d 2>/dev/null || date -v-90d +%Y-%m-%d 2>/dev/null)

          # Add metadata
          echo "<!-- last_deep_clean=$TODAY, merge_count=$PR_NUMBER -->" > "$DEEP_CLEAN_TEMP"
          echo "" >> "$DEEP_CLEAN_TEMP"

          # Process scratchpad sections intelligently
          awk -v cutoff_30="$CUTOFF_30" -v cutoff_60="$CUTOFF_60" -v cutoff_90="$CUTOFF_90" '
            BEGIN {
              in_archive = 0
              archive_count = 0
              old_entries = ""
            }

            # Keep header and HIGH PRIORITY as-is (user manages this manually)
            /^# Sharkrite Scratchpad/,/^## 🔥 HIGH PRIORITY/ { print; next }
            /^## 🔥 HIGH PRIORITY/,/^##/ {
              if (/^##/ && !/^## 🔥 HIGH PRIORITY/) {
                # End of HIGH PRIORITY section
              } else {
                print
                next
              }
            }

            # Keep Current Work section as-is (active branches)
            /^## Current Work/,/^##/ {
              if (/^##/ && !/^## Current Work/) {
                # End of Current Work
              } else {
                print
                next
              }
            }

            # Keep Project Notes, Useful Commands, References as-is for now
            # (Manual curation is better for these)
            /^## Project Notes/,/^## Completed Work Archive/ { print; next }
            /^## Useful Commands/,/^##/ {
              if (/^##/ && !/^## Useful Commands/) {
              } else { print; next }
            }
            /^## References/,/^##/ {
              if (/^##/ && !/^## References/) {
              } else { print; next }
            }

            # Completed Work Archive: keep last 20, summarize older
            /^## Completed Work Archive/ {
              in_archive = 1
              print
              print ""
              next
            }

            in_archive && /^### [0-9]{4}-[0-9]{2}-[0-9]{2}:/ {
              archive_count++
              if (archive_count <= 20) {
                # Keep recent entries
                entry = $0
                while (getline > 0) {
                  if (/^###/ || /^##/) {
                    # Next section
                    print entry
                    print ""
                    in_archive = 0
                    break
                  }
                  entry = entry "\n" $0
                }
                if (in_archive) print entry
              } else {
                # Skip old entries (could summarize later)
                while (getline > 0) {
                  if (/^###/ || /^##/) {
                    in_archive = 0
                    break
                  }
                }
              }
              next
            }

            # Print everything else
            { print }
          ' "$SCRATCHPAD_FILE" >> "$DEEP_CLEAN_TEMP"

          ORIGINAL_LINES=$(wc -l < "$SCRATCHPAD_FILE")
          NEW_LINES=$(wc -l < "$DEEP_CLEAN_TEMP")

          mv "$DEEP_CLEAN_TEMP" "$SCRATCHPAD_FILE"
          FINAL_SIZE_KB=$(( $(wc -c < "$SCRATCHPAD_FILE") / 1024 ))
          if [ "$NEW_LINES" -lt "$ORIGINAL_LINES" ]; then
            print_success "Deep clean complete (pruned $(( ORIGINAL_LINES - NEW_LINES )) lines, kept last 20 archived PRs, ${FINAL_SIZE_KB}KB)"
          else
            print_success "Deep clean complete (nothing to prune, kept last 20 archived PRs, ${FINAL_SIZE_KB}KB)"
          fi

          # Cleanup old managed stashes (marked with RITE_MARKER_STASH)
          print_status "Cleaning up old [${RITE_MARKER_STASH}] stashes..."
          cleanup_sharkrite_stashes "$MAIN_WORKTREE"

          # Check HIGH PRIORITY completion status
          print_status "Checking HIGH PRIORITY items completion status..."

          HIGH_PRIORITY=$(sed -n '/^## 🔥 HIGH PRIORITY/,/^## /p' "$SCRATCHPAD_FILE" | sed '$d' || true)

          if [ -n "$HIGH_PRIORITY" ]; then
            # Check each item against git history
            # Extract item titles and check if corresponding PRs merged
              while IFS= read -r line; do
                if [[ "$line" =~ ^###[[:space:]](.+) ]]; then
                  ITEM_TITLE="${BASH_REMATCH[1]}"
                  # Check if this was completed (look for PR in git log)
                  RELATED_PR=$(git log --all --grep="$ITEM_TITLE" --oneline -1 2>/dev/null)
                  if [ -n "$RELATED_PR" ]; then
                    print_info "Found completed: $ITEM_TITLE (may need status update)"
                  fi
                fi
              done <<< "$HIGH_PRIORITY"
            fi
          fi

          # Step 4: Clean up stale worktrees
          print_status "Checking for stale worktrees..."

          EXISTING_WORKTREES=$(git worktree list --porcelain | grep -E "^worktree $RITE_WORKTREE_DIR" | sed 's/^worktree //' || echo "")

          STALE_COUNT=0
          REMOVED_COUNT=0
          REMOVED_BRANCHES=()

          if [ -n "$EXISTING_WORKTREES" ]; then
            while IFS= read -r wt_path; do
              [ -z "$wt_path" ] && continue

              # Skip the worktree we're about to remove ourselves (prevents double-remove)
              [ "$wt_path" = "$CURRENT_DIR" ] && continue

              WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "unknown")
              UNCOMMITTED_COUNT=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

              # Check if branch has been merged/deleted
              BRANCH_EXISTS=$(git show-ref --verify --quiet refs/heads/"$WT_BRANCH" && echo "yes" || echo "no")

              # Check last modification (any source file, not just .ts/.js)
              # portable_find_max_mtime reads NUL-delimited paths from find -print0
              # and already returns "0" when no files are found; || true avoids silent
              # script death under set -euo pipefail without producing a double "0".
              #
              # -not -type l: skip symlinks — broken symlinks produce mtime=0 from
              #   stat, which causes portable_find_max_mtime to return 0 → DAYS_OLD=999
              #   → false stale verdict that destroys uncommitted source files.
              # -not -path exclusions: don't traverse .venv/.rite (symlinks in worktrees
              #   pointing back to main) or node_modules/vendor (stale dep timestamps).
              LAST_MODIFIED=$(find "$wt_path" -type f -not -type l \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rb" -o -name "*.rs" -o -name "*.java" -o -name "*.sh" -o -name "*.tsx" -o -name "*.jsx" -o -name "*.vue" -o -name "*.swift" -o -name "*.kt" \) -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/.rite/*" -not -path "*/vendor/*" -print0 2>/dev/null \
                | portable_find_max_mtime || true)
              [ "${LAST_MODIFIED:-0}" = "0" ] && LAST_MODIFIED=""

              # Fallback: check ANY file modification if no source files found
              if [ -z "$LAST_MODIFIED" ]; then
                LAST_MODIFIED=$(find "$wt_path" -type f -not -type l -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/.rite/*" -print0 2>/dev/null \
                  | portable_find_max_mtime || true)
                [ "${LAST_MODIFIED:-0}" = "0" ] && LAST_MODIFIED=""
              fi

              if [ -n "$LAST_MODIFIED" ]; then
                DAYS_OLD=$(( ( $(date +%s) - LAST_MODIFIED ) / 86400 ))
              else
                DAYS_OLD=999
              fi

              IS_STALE=false
              STALE_REASON=""

              # In batch mode, protect worktrees belonging to sibling issues
              if [ "${BATCH_MODE:-false}" = true ] && [ -n "${BATCH_ISSUE_LIST:-}" ]; then
                WT_PROTECTED=false
                for batch_issue in $BATCH_ISSUE_LIST; do
                  # Check if this worktree's branch references a batch issue number
                  if echo "$WT_BRANCH" | grep -qE "(^|[^0-9])${batch_issue}([^0-9]|$)"; then
                    WT_PROTECTED=true
                    break
                  fi
                done
                if [ "$WT_PROTECTED" = true ]; then
                  continue
                fi
              fi

              # Determine if stale (same logic as cleanup-worktrees.sh)
              if [ "$BRANCH_EXISTS" = "no" ]; then
                IS_STALE=true
                STALE_REASON="Branch deleted/merged"
              elif [ "$UNCOMMITTED_COUNT" -eq 0 ] && [ "$DAYS_OLD" -gt 14 ]; then
                IS_STALE=true
                STALE_REASON="No activity for $DAYS_OLD days"
              fi

              if [ "$IS_STALE" = true ]; then
                STALE_COUNT=$((STALE_COUNT + 1))
                print_info "Removing stale worktree: $(basename "$wt_path") ($STALE_REASON)"

                # Stash any uncommitted changes (safety check)
                UNCOMMITTED=$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "")
                if [ -n "$UNCOMMITTED" ]; then
                  git -C "$wt_path" stash push -m "Auto-stash before cleanup: $WT_BRANCH - $(date +%Y-%m-%d)" 2>/dev/null || true
                fi

                # Remove worktree
                if git worktree remove "$wt_path" --force 2>/dev/null || git worktree remove "$wt_path" 2>/dev/null; then
                  REMOVED_COUNT=$((REMOVED_COUNT + 1))
                  REMOVED_BRANCHES+=("$WT_BRANCH ($STALE_REASON)")
                fi
              fi
            done <<< "$EXISTING_WORKTREES"

            if [ "$REMOVED_COUNT" -gt 0 ]; then
              print_success "Removed $REMOVED_COUNT stale worktree(s)"
            else
              print_success "No stale worktrees to clean"
            fi
          fi

          # Step 5: Send Slack notification summary
          if [ -n "${SLACK_WEBHOOK:-}" ]; then
            print_status "Sending deep clean summary to Slack..."

            # Calculate totals
            SCRATCHPAD_LINES_REMOVED=$(( ORIGINAL_LINES > NEW_LINES ? ORIGINAL_LINES - NEW_LINES : 0 ))

            # Build removed worktrees list
            REMOVED_WORKTREES_LIST=""
            if [ ${#REMOVED_BRANCHES[@]} -gt 0 ]; then
              for branch_info in "${REMOVED_BRANCHES[@]}"; do
                REMOVED_WORKTREES_LIST="${REMOVED_WORKTREES_LIST}  ◦ ${branch_info}\n"
              done
            else
              REMOVED_WORKTREES_LIST="  ◦ None\n"
            fi

            # Build active worktrees list
            ACTIVE_WORKTREES_LIST=""

            # Re-scan to get current active worktrees
            CURRENT_WORKTREES=$(git worktree list --porcelain | grep -E "^worktree $RITE_WORKTREE_DIR" | sed 's/^worktree //' || echo "")
            if [ -n "$CURRENT_WORKTREES" ]; then
              while IFS= read -r wt_path; do
                [ -z "$wt_path" ] && continue
                WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "unknown")
                ACTIVE_WORKTREES_LIST="${ACTIVE_WORKTREES_LIST}  ◦ ${WT_BRANCH}\n"
              done <<< "$CURRENT_WORKTREES"
            else
              ACTIVE_WORKTREES_LIST="  ◦ None\n"
            fi

            # Build summary message
            CLEAN_SUMMARY="🧹 *Periodic Deep Clean Complete*

📝 *Scratchpad*
• Removed $SCRATCHPAD_LINES_REMOVED lines
• Size: $(( $(wc -c < "$SCRATCHPAD_FILE") / 1024 ))KB
• Kept last 20 archived PRs

🌳 *Worktrees*
• Removed ($REMOVED_COUNT):
${REMOVED_WORKTREES_LIST}
• Active ($(echo "$ACTIVE_WORKTREES_LIST" | grep -c '◦' || echo 0)):
${ACTIVE_WORKTREES_LIST}
📦 *Backups*
• Scratchpad backup: $(basename "$SCRATCHPAD_BACKUP")
• Kept last 5 backups

⏰ Last deep clean: $TODAY
📊 Total PRs merged: #$PR_NUMBER"

            # Send to Slack
            # sharkrite-lint disable UNQUOTED_HEREDOC - Intentional: variables must be expanded
            SLACK_PAYLOAD=$(cat <<EOF
{
  "text": "Periodic Deep Clean Summary",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "$CLEAN_SUMMARY"
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "Repository: \`${RITE_PROJECT_NAME}\` | Triggered by PR #$PR_NUMBER merge"
        }
      ]
    }
  ]
}
EOF
)

            HTTP_CODE=$(curl -X POST "$SLACK_WEBHOOK" \
              -H "Content-Type: application/json" \
              -d "$SLACK_PAYLOAD" \
              -w "%{http_code}" \
              -s -o /dev/null 2>/dev/null || echo "000")

          if [ "$HTTP_CODE" = "200" ]; then
            print_success "Slack notification sent"
          else
            print_warning "Slack notification failed (HTTP $HTTP_CODE)"
          fi
        fi
      fi

      # Release scratchpad lock via shared module (safe to call even if no scratchpad work occurred)
        release_scratchpad_lock
        # Restore original trap now that the lock is released — only temp-file cleanup remains.
        trap cleanup_temp_files EXIT ERR INT TERM

        # Clean up old backups (keep last 5).
        # Use ls -t (mtime sort, newest first) so the 6th+ entries are the oldest backups.
        SCRATCHPAD_DIR=$(dirname "$SCRATCHPAD_FILE")
        SCRATCHPAD_BASENAME=$(basename "$SCRATCHPAD_FILE")
        # shellcheck disable=SC2012
        ls -t "$SCRATCHPAD_DIR/${SCRATCHPAD_BASENAME}.backup-"* 2>/dev/null \
          | tail -n +6 | while IFS= read -r _old_backup; do rm -f "$_old_backup"; done || true
        if [ "${RITE_VERBOSE:-false}" = "true" ]; then
          print_success "Scratchpad backup created: $(basename "$SCRATCHPAD_BACKUP")"
        fi
      fi

      # Remove worktree — work is merged, nothing to preserve
      # (already cd'd to MAIN_WORKTREE at top of this block)
      if git worktree remove "$CURRENT_DIR" --force 2>/dev/null; then
        echo -e "${GREEN}  ✓ Removed worktree: $(basename "$CURRENT_DIR")${NC}"
      else
        print_warning "Could not remove worktree: $CURRENT_DIR"
        print_info "Remove manually: git worktree remove '$CURRENT_DIR' --force"
      fi
      # Prune stale worktree metadata so branch -D doesn't fail with "checked out at"
      git worktree prune 2>/dev/null || true
      # Retry branch deletion now that worktree is fully pruned
      git branch -D "$PR_HEAD" 2>/dev/null || true
      CURRENT_DIR="$MAIN_WORKTREE"
    fi

  if is_verbose; then
    verbose_header "🎉 Merge Complete"
    echo "Summary:"
    echo "  ✓ PR #$PR_NUMBER merged into $PR_BASE"
    echo "  ✓ Remote branch deleted: origin/$PR_HEAD"
    echo "  ✓ Local branch deleted: $PR_HEAD"
    echo "  ✓ Security guide updated (if applicable)"
    echo "  ✓ Scratchpad cleaned"
    echo ""
    echo "Next steps:"
    echo "  1. Verify deployment if applicable"
    echo "  2. Monitor for any issues"
    echo "  3. Update project board if using one"
    echo ""
  fi
  # Wait for background doc assessment and report results.
  # Bounded by RITE_DOC_ASSESSMENT_TIMEOUT (default 300s): if the assessment
  # hangs (Claude API outage, network drop), a watchdog kills the background
  # process and we continue — stale/missing doc updates are not a merge blocker.
  # Default 300s: with doc_assessment on sonnet, typical wall-clock is ~90-120s
  # (fan-out ~30s + reconcile ~30s + validate ~30s). 300s gives headroom for
  # big diffs and slow API responses without firing on normal runs.
  if [ -n "${_DOC_PID:-}" ]; then
    _doc_exit=0
    _doc_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"

    # Start a watchdog: after the timeout, SIGTERM the doc assessment subprocess.
    # The watchdog itself is killed when the doc assessment finishes first.
    ( sleep "$_doc_timeout" && kill -TERM "$_DOC_PID" 2>/dev/null ) &
    _doc_watchdog_pid=$!

    wait "$_DOC_PID" 2>/dev/null || _doc_exit=$?

    # Cancel the watchdog if the doc assessment finished before the timeout.
    kill -TERM "$_doc_watchdog_pid" 2>/dev/null || true
    wait "$_doc_watchdog_pid" 2>/dev/null || true

    if [ "$_doc_exit" -eq 143 ] || [ "$_doc_exit" -eq 137 ]; then
      # 143 = SIGTERM (128+15), 137 = SIGKILL (128+9) — both mean timed out.
      # Harvest any sub-assessments that completed before the kill.
      # Each sub-assessment writes "partial_complete:<name>" to the process
      # stdout (captured in _DOC_LOG) as soon as it writes its doc update.
      # Reading _DOC_LOG here gives us a count of what finished vs what was lost.
      _completed_partials=0
      if [ -s "${_DOC_LOG:-}" ]; then
        _completed_partials=$(grep -c "^partial_complete:" "$_DOC_LOG" 2>/dev/null || true)
      fi
      if [ "$_completed_partials" -gt 0 ]; then
        print_warning "Documentation assessment timed out after ${_doc_timeout}s — preserving $_completed_partials completed sub-assessment(s)" >&2
        # Show which sub-assessments completed (doc files already written to disk)
        grep "^partial_complete:" "$_DOC_LOG" 2>/dev/null | sed 's/^partial_complete:/  ✓ /' >&2 || true
      else
        print_warning "Documentation assessment timed out after ${_doc_timeout}s — no sub-assessments completed before timeout" >&2
      fi
    elif [ $_doc_exit -ne 0 ] && [ $_doc_exit -ne 2 ]; then
      # Surface failure visibly: warning + last 20 lines of log to stderr so
      # the user sees why the assessment failed even in auto/piped mode.
      print_warning "Documentation assessment failed (exit $_doc_exit)" >&2
      if [ -s "${_DOC_LOG:-}" ]; then
        echo "--- doc-assessment log (last 20 lines) ---" >&2
        tail -20 "$_DOC_LOG" >&2
        echo "---" >&2
      fi
    elif [ -s "${_DOC_LOG:-}" ]; then
      # Success: show full summary output (Documentation header + results)
      # Filter internal partial_complete: protocol markers — they are Layer B
      # coordination signals and must not surface in user-facing output.
      grep -v '^partial_complete:' "$_DOC_LOG" || true
    fi
  fi
  rm -f "${_DOC_LOG:-}"

  echo "PR URL: $PR_URL"
  echo ""

  # Check if cleanup failed — if so, exit with code 6 (not 0) so the batch reporter
  # can distinguish "merge succeeded but cleanup crashed" from "everything succeeded"
  if [ "$CLEANUP_FAILED" = true ]; then
    print_warning "PR merged successfully, but post-merge cleanup encountered errors"
    print_info "Work is on remote (PR #$PR_NUMBER merged to $PR_BASE)"
    exit 6
  fi

  exit 0
else
  verbose_header "❌ Merge Failed"
  echo ""
  echo "Error output:"
  echo "$MERGE_OUTPUT"
  echo ""
  echo "Possible reasons:"
  echo "  - Branch protection rules blocking merge"
  echo "  - Required reviews not met"
  echo "  - Status checks still pending"
  echo "  - Merge conflicts detected"
  echo ""
  echo "To debug:"
  echo "  gh pr view $PR_NUMBER --web"
  echo "  gh pr checks $PR_NUMBER"
  echo ""
  exit 1
fi
