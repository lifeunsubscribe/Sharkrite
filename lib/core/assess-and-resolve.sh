#!/bin/bash
# scripts/assess-and-resolve.sh
# Comprehensive PR review assessment with automatic issue categorization
# Usage:
#   ./scripts/assess-and-resolve.sh PR_NUMBER [ISSUE_NUMBER] [--auto]
#
# Exit codes:
#   0 - All issues resolved or tracked
#   1 - Manual intervention required (supervisor decision needed)
#   2 - Critical issues require fixes (restart PR cycle, outputs filtered review to stdout)
#   3 - Review is stale (commits newer than review — route back to Phase 2 for fresh review)
#
# Data flow (auto mode):
#   - Calls assess-review-issues.sh to filter ACTIONABLE items
#   - Outputs filtered review content to stdout on exit 2
#   - workflow-runner.sh captures stdout and pipes to claude-workflow.sh (no temp files!)

set -euo pipefail

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../utils/config.sh"
fi

# Source review helper for consistent review method handling
source "$RITE_LIB_DIR/utils/review-helper.sh"

# Source PR detection for shared commit timestamp utility
source "$RITE_LIB_DIR/utils/pr-detection.sh"

# Redirect all display output to stderr (stdout reserved for filtered content on exit 2)
exec 3>&1  # Save original stdout for filtered content output
exec 1>&2  # Redirect stdout to stderr for all print functions

# DEBUG: Trap to catch what's causing non-zero exit
trap 'echo "[ASSESS-RESOLVE TRAP] Exit code: $? at line $LINENO" >&2' ERR

# Temp file cleanup trap handler (minimal - only for initial review fetch)
cleanup() {
  local exit_code=$?
  # Clean up minimal temp files on exit
  # Note: REVIEW_FILE is kept minimal (only for initial gh pr view)
  # All assessment data flows through variables/pipes (no temp files)
  rm -f /tmp/pr_review_*.txt 2>/dev/null || true
  exit $exit_code
}
trap cleanup EXIT INT TERM

# Parse arguments
PR_NUMBER="$1"
ISSUE_NUMBER="${2:-}"
RETRY_COUNT="${3:-0}"  # Default to 0 if not provided
AUTO_MODE=false

# Validate PR number is positive integer
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || [ "$PR_NUMBER" -le 0 ] 2>/dev/null; then
  echo "❌ Invalid PR number: $PR_NUMBER (must be positive integer)"
  exit 1
fi

# Safety check: Prevent unbounded recursion
# Can be overridden via environment variable
MAX_RETRIES="${RITE_MAX_RETRIES:-3}"
if [ "$RETRY_COUNT" -gt "$MAX_RETRIES" ]; then
  echo "❌ Maximum retry limit exceeded ($RETRY_COUNT > $MAX_RETRIES)"
  echo "Preventing unbounded recursion - manual intervention required"
  exit 1
fi

# Handle --auto flag (can be 2nd, 3rd, or 4th argument)
if [ "${2:-}" = "--auto" ] || [ "${3:-}" = "--auto" ] || [ "${4:-}" = "--auto" ]; then
  AUTO_MODE=true
fi

# If 2nd argument is --auto, clear ISSUE_NUMBER
if [ "$ISSUE_NUMBER" = "--auto" ]; then
  ISSUE_NUMBER=""
  RETRY_COUNT="${3:-0}"
fi

# If 3rd argument is --auto, RETRY_COUNT is 4th
if [ "${3:-}" = "--auto" ]; then
  RETRY_COUNT="${4:-0}"
fi

# Validate ISSUE_NUMBER if provided (similar to PR_NUMBER validation)
if [ -n "$ISSUE_NUMBER" ]; then
  if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]] || [ "$ISSUE_NUMBER" -le 0 ] 2>/dev/null; then
    echo "❌ Invalid issue number: $ISSUE_NUMBER (must be positive integer)"
    exit 1
  fi
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
  echo -e "${BLUE}$1${NC}" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}

print_success() { echo -e "${GREEN}✅ $1${NC}" >&2; }
print_error() { echo -e "${RED}❌ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}" >&2; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}" >&2; }
print_status() { echo -e "${BLUE}$1${NC}" >&2; }
print_critical() { echo -e "${RED}🚨 CRITICAL: $1${NC}" >&2; }
print_high() { echo -e "${MAGENTA}⚡ HIGH: $1${NC}" >&2; }
print_medium() { echo -e "${YELLOW}📋 MEDIUM: $1${NC}" >&2; }
print_low() { echo -e "${BLUE}💡 LOW: $1${NC}" >&2; }

# Print detailed assessment breakdown showing each item and reasoning
print_assessment_details() {
  local assessment_content="$1"

  # Disable errexit for this function to prevent grep failures from causing script exit
  set +e

  # Parse items from assessment (format: ### Title - STATE)
  # Extract sections between ### markers

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 Assessment Details:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Extract and display ACTIONABLE_NOW items
  local now_items=$(echo "$assessment_content" | grep -A 20 "ACTIONABLE_NOW" 2>/dev/null | grep -B 1 "ACTIONABLE_NOW" 2>/dev/null || true)
  if [ -n "$now_items" ]; then
    echo "🔴 ACTIONABLE_NOW (fix in this PR):" >&2
    echo "" >&2

    # Parse each item
    echo "$assessment_content" | awk '
      /^### .* - ACTIONABLE_NOW/ {
        in_item = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - ACTIONABLE_NOW.*$/, "", title)
        printf "  • %s\n", title
        next
      }
      in_item && /^\*\*Severity:\*\*/ {
        severity = $0
        gsub(/^\*\*Severity:\*\* /, "", severity)
        printf "    Severity: %s\n", severity
        next
      }
      in_item && /^\*\*Reasoning:\*\*/ {
        reasoning = $0
        gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
        # Print reasoning with proper wrapping using fold
        printf "    Reason: "
        system("echo \"" reasoning "\" | fold -w 76 -s | sed \"2,\\$s/^/            /\"")
        next
      }
      in_item && /^\*\*Fix Effort:\*\*/ {
        effort = $0
        gsub(/^\*\*Fix Effort:\*\* /, "", effort)
        printf "    Effort: %s\n", effort
        printf "\n"
        in_item = 0
        next
      }
      in_item && /^### / {
        # New item started, reset
        in_item = 0
        printf "\n"
      }
    '
  fi

  # Extract and display ACTIONABLE_LATER items
  local later_items=$(echo "$assessment_content" | grep -A 20 "ACTIONABLE_LATER" 2>/dev/null | grep -B 1 "ACTIONABLE_LATER" 2>/dev/null || true)
  if [ -n "$later_items" ]; then
    echo "🟡 ACTIONABLE_LATER (defer to follow-up):"
    echo ""

    echo "$assessment_content" | awk '
      /^### .* - ACTIONABLE_LATER/ {
        in_item = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - ACTIONABLE_LATER.*$/, "", title)
        printf "  • %s\n", title
        next
      }
      in_item && /^\*\*Severity:\*\*/ {
        severity = $0
        gsub(/^\*\*Severity:\*\* /, "", severity)
        printf "    Severity: %s\n", severity
        next
      }
      in_item && /^\*\*Reasoning:\*\*/ {
        reasoning = $0
        gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
        # Print reasoning with proper wrapping using fold
        printf "    Reason: "
        system("echo \"" reasoning "\" | fold -w 76 -s | sed \"2,\\$s/^/            /\"")
        next
      }
      in_item && /^\*\*Defer Reason:\*\*/ {
        defer = $0
        gsub(/^\*\*Defer Reason:\*\* /, "", defer)
        # Print defer reason with proper wrapping using fold
        printf "    Defer: "
        system("echo \"" defer "\" | fold -w 76 -s | sed \"2,\\$s/^/            /\"")
        printf "\n"
        in_item = 0
        next
      }
      in_item && /^### / {
        in_item = 0
        printf "\n"
      }
    '
  fi

  # Extract and display DISMISSED items
  local dismissed_items=$(echo "$assessment_content" | grep -A 20 "DISMISSED" 2>/dev/null | grep -B 1 "DISMISSED" 2>/dev/null || true)
  if [ -n "$dismissed_items" ]; then
    echo "⚪ DISMISSED (not worth tracking):"
    echo ""

    echo "$assessment_content" | awk '
      /^### .* - DISMISSED/ {
        in_item = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - DISMISSED.*$/, "", title)
        printf "  • %s\n", title
        next
      }
      in_item && /^\*\*Reasoning:\*\*/ {
        reasoning = $0
        gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
        # Print reasoning with proper wrapping using fold
        printf "    Reason: "
        system("echo \"" reasoning "\" | fold -w 76 -s | sed \"2,\\$s/^/            /\"")
        printf "\n"
        in_item = 0
        next
      }
      in_item && /^### / {
        in_item = 0
        printf "\n"
      }
    '
  fi

  # Re-enable errexit
  set -e

  echo ""
  return 0
}

# Format ISO timestamp to human-readable format
# Input: 2025-10-28T20:42:18Z (ISO 8601 UTC)
# Output: Oct 28, 2025 - 2:42 PM MT
format_review_timestamp() {
  local iso_timestamp="$1"

  # Detect GNU vs BSD date
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    date -d "$iso_timestamp" "+%b %d, %Y - %-I:%M %p %Z" 2>/dev/null || echo "$iso_timestamp"
  else
    # BSD date (macOS)
    # Extract components manually since BSD date is picky about ISO format
    local year month day time
    year=$(echo "$iso_timestamp" | cut -d'T' -f1 | cut -d'-' -f1)
    month=$(echo "$iso_timestamp" | cut -d'T' -f1 | cut -d'-' -f2)
    day=$(echo "$iso_timestamp" | cut -d'T' -f1 | cut -d'-' -f3)
    time=$(echo "$iso_timestamp" | cut -d'T' -f2 | cut -d'Z' -f1)

    # Parse into BSD date format
    date -j -f "%Y-%m-%d %H:%M:%S" "$year-$month-$day $time" "+%b %d, %Y - %-I:%M %p %Z" 2>/dev/null || echo "$iso_timestamp"
  fi
}

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  print_error "jq required: brew install jq"
  exit 1
fi

# Fetch PR review (local sharkrite review comment)
# (header already printed by workflow-runner.sh with PR + issue context)
GH_STDERR=$(mktemp)
REVIEW_JSON=$(gh pr view "$PR_NUMBER" --json comments --jq '[.comments[] | select(.author.login == "claude" or .author.login == "claude[bot]" or .author.login == "github-actions[bot]" or (.body | contains("<!-- sharkrite-local-review")))] | .[-1]' 2>"$GH_STDERR") || {
  GH_ERROR=$(cat "$GH_STDERR")
  rm -f "$GH_STDERR"
  print_error "Failed to fetch PR #$PR_NUMBER"
  if [ -n "$GH_ERROR" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "GitHub CLI Error:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$GH_ERROR"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  exit 1
}
rm -f "$GH_STDERR"

if [ "$REVIEW_JSON" = "{}" ] || [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
  # No review found - auto-generate one
  print_status "No review found - generating local review..."
  echo ""

  # Run local review with --post --auto
  LOCAL_REVIEW_SCRIPT="$RITE_LIB_DIR/core/local-review.sh"
  if [ -f "$LOCAL_REVIEW_SCRIPT" ]; then
    if "$LOCAL_REVIEW_SCRIPT" "$PR_NUMBER" --post --auto; then
      print_success "Local review posted"
      echo ""

      # Re-fetch the review we just posted
      sleep 2  # Give GitHub a moment to index
      REVIEW_JSON=$(gh pr view "$PR_NUMBER" --json comments --jq '[.comments[] | select(.body | contains("<!-- sharkrite-local-review"))] | .[-1]' 2>/dev/null) || true

      if [ "$REVIEW_JSON" = "{}" ] || [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
        print_error "Failed to fetch newly posted review"
        exit 1
      fi
    else
      print_error "Local review generation failed"
      exit 1
    fi
  else
    print_error "Local review script not found: $LOCAL_REVIEW_SCRIPT"
    exit 1
  fi
fi

REVIEW_BODY=$(echo "$REVIEW_JSON" | jq -r '.body' 2>/dev/null || echo "")

if [ -z "$REVIEW_BODY" ] || [ "$REVIEW_BODY" = "null" ]; then
  print_error "Review body is empty"
  exit 1
fi

# Save review to temp file for parsing
REVIEW_FILE="/tmp/pr_review_${PR_NUMBER}.txt"
echo "$REVIEW_BODY" > "$REVIEW_FILE"

print_success "Review fetched from PR #$PR_NUMBER"
echo ""

# =============================================================================
# Extract model from review metadata for assessment consistency
# =============================================================================

extract_review_model() {
  local review_body="$1"
  local model=$(echo "$review_body" | grep -oE 'sharkrite-local-review model:[a-z0-9-]+' | sed 's/.*model://' | head -1)
  if [ -n "$model" ]; then
    echo "$model"
  else
    echo "$RITE_REVIEW_MODEL"
  fi
}

REVIEW_MODEL=$(extract_review_model "$REVIEW_BODY")
print_info "Review model: $REVIEW_MODEL"
export RITE_ASSESSMENT_MODEL="$REVIEW_MODEL"

# =============================================================================
# Extract structured JSON from review (new format with sharkrite-review-data)
# Falls back to markdown parsing for older reviews
# =============================================================================

extract_review_json() {
  local review_body="$1"
  # Extract JSON from <!-- sharkrite-review-data ... --> block
  local json_block=$(echo "$review_body" | sed -n '/<!-- sharkrite-review-data/,/-->/p' | sed '1d;$d')
  if [ -n "$json_block" ] && echo "$json_block" | jq empty 2>/dev/null; then
    echo "$json_block"
  else
    echo ""
  fi
}

REVIEW_JSON_DATA=$(extract_review_json "$REVIEW_BODY")

if [ -n "$REVIEW_JSON_DATA" ]; then
  print_info "Found structured review data (JSON format)"
  # Parse counts from JSON
  JSON_CRITICAL=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.critical // 0' 2>/dev/null || echo "0")
  JSON_HIGH=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.high // 0' 2>/dev/null || echo "0")
  JSON_MEDIUM=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.medium // 0' 2>/dev/null || echo "0")
  JSON_LOW=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.low // 0' 2>/dev/null || echo "0")
  JSON_VERDICT=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
  JSON_ITEMS_COUNT=$(echo "$REVIEW_JSON_DATA" | jq -r '.items | length // 0' 2>/dev/null || echo "0")

  print_info "JSON summary: CRITICAL=$JSON_CRITICAL HIGH=$JSON_HIGH MEDIUM=$JSON_MEDIUM LOW=$JSON_LOW"
  print_info "JSON verdict: $JSON_VERDICT (${JSON_ITEMS_COUNT} items)"

  # Export for use by downstream tools
  export RITE_REVIEW_JSON="$REVIEW_JSON_DATA"
  export RITE_REVIEW_FORMAT="json"
else
  print_info "No structured JSON found - will use markdown parsing"
  export RITE_REVIEW_FORMAT="markdown"
fi

# Check if review is stale (commits pushed after review).
# Runs on every invocation, including retries. Phase 2 should push fix commits
# and generate a fresh review before Phase 3 re-enters, but if that fails
# (e.g., push skipped, review generation failed), this catches it as a safety net.
if [ "$RETRY_COUNT" -gt 0 ]; then
  print_status "Retry $RETRY_COUNT: Checking review currency..."
else
  print_status "Checking if review is current..."
fi
echo ""

# Get review timestamp
REVIEW_TIME="${REVIEW_TIME:-$(echo "$REVIEW_JSON" | jq -r '.createdAt' 2>/dev/null)}"

# Get latest commit timestamp (local git preferred, API fallback)
get_latest_work_commit_time "." "$PR_NUMBER"

# Check if there are commits after the review
if [ -n "$LATEST_COMMIT_TIME" ] && [ -n "$REVIEW_TIME" ]; then
  # Convert ISO timestamps to seconds since epoch for reliable comparison
  # Portable date parsing: detect GNU vs BSD date
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    COMMIT_EPOCH=$(date -d "$LATEST_COMMIT_TIME" "+%s" 2>/dev/null || echo "0")
    REVIEW_EPOCH=$(date -d "$REVIEW_TIME" "+%s" 2>/dev/null || echo "0")
  else
    # BSD date (macOS)
    COMMIT_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$LATEST_COMMIT_TIME" "+%s" 2>/dev/null || echo "0")
    REVIEW_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$REVIEW_TIME" "+%s" 2>/dev/null || echo "0")
  fi

  if [ "$COMMIT_EPOCH" -gt "$REVIEW_EPOCH" ]; then
    print_warning "Review is stale — commits pushed after review"
    echo "  Review created: $REVIEW_TIME"
    echo "  Latest commit:  $LATEST_COMMIT_TIME"
    echo ""

    # Check if there's a newer review we missed (bot accounts OR local sharkrite reviews)
    ALL_REVIEWS=$(gh pr view "$PR_NUMBER" --json comments --jq '[.comments[] | select(.author.login == "claude" or .author.login == "github-actions[bot]" or (.body | contains("<!-- sharkrite-local-review")))] | sort_by(.createdAt) | reverse' 2>/dev/null)

    NEWER_REVIEW_COUNT=$(echo "$ALL_REVIEWS" | jq '[.[] | select(.createdAt > "'"$LATEST_COMMIT_TIME"'")] | length' 2>/dev/null || echo "0")

    if [ "$NEWER_REVIEW_COUNT" -gt 0 ]; then
      # A newer review exists — use it instead
      print_info "Found newer review after latest commit — using that instead"
      REVIEW_JSON=$(echo "$ALL_REVIEWS" | jq '.[0]' 2>/dev/null)
      REVIEW_BODY=$(echo "$REVIEW_JSON" | jq -r '.body' 2>/dev/null)
      echo "$REVIEW_BODY" > "$REVIEW_FILE"
      print_success "Using current review (created after latest commit)"
      echo ""
    else
      # No current review exists. Route back to Phase 2 for proper
      # push + review generation via the standard pipeline (create-pr.sh
      # → local-review.sh). Phase 3 should only assess, not generate.
      print_info "No current review found — routing back to review phase"
      exit 3
    fi
  fi
  fi

# ============================================================================
# RAW REVIEW DISPLAY: Show what Claude will see (compact format for debugging)
# ============================================================================

# Format timestamp for display
FORMATTED_TIME=$(format_review_timestamp "$REVIEW_TIME")

print_header "📄 Code Review: $FORMATTED_TIME"

# Compact display: format review using dedicated formatter
if [ -f "$RITE_LIB_DIR/utils/format-review.sh" ]; then
  "$RITE_LIB_DIR/utils/format-review.sh" "$REVIEW_FILE"
else
  # Fallback: simple compact display
  cat "$REVIEW_FILE" | sed '/^$/N;/^\n$/d'
  print_warning "format-review.sh not found - using fallback display"
fi
echo ""

# ============================================================================
# SMART ASSESSMENT: Use Claude CLI to filter ACTIONABLE items
# This runs BEFORE displaying summary so counts are accurate
# ============================================================================

# Early exit: if the review has zero findings across all severities, skip
# assessment entirely and go straight to merge. The assessment's job is to
# categorize review findings — when there are none, there's nothing to categorize.
# Without this, the assessment Claude reads positive prose and invents issues.
REVIEW_FINDINGS_LINE=$(grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+ [|] LOW: [0-9]+" "$REVIEW_FILE" 2>/dev/null | head -1 || true)
if [ -n "$REVIEW_FINDINGS_LINE" ]; then
  REVIEW_TOTAL_FINDINGS=$(echo "$REVIEW_FINDINGS_LINE" | grep -oE "[0-9]+" | awk '{sum += $1} END {print sum}')
  if [ "${REVIEW_TOTAL_FINDINGS:-0}" -eq 0 ]; then
    print_header "🦈 Smart Assessment (Sharkrite)"
    print_success "Review has zero findings — skipping assessment, proceeding to merge"
    echo ""
    exit 0
  fi
fi

print_header "🦈 Smart Assessment (Sharkrite)"

ACTIONABLE_COUNT=0

if [ -f "$RITE_LIB_DIR/core/assess-review-issues.sh" ]; then
  # Only show retry count if actually retrying (count > 0)
  if [ "$RETRY_COUNT" -gt 0 ]; then
    print_status "Running Claude CLI assessment (retry $RETRY_COUNT/3)..."
  else
    print_status "Running Claude CLI assessment on all review issues..."
  fi

  # Run smart assessment - pass --auto flag if in auto mode
  # assess-review-issues.sh performs HOLISTIC analysis of entire PR comment
  # and categorizes ALL contents, outputting filtered ACTIONABLE items to stdout
  # Use process substitution to show stderr in real-time (Claude output streams to terminal)
  ASSESSMENT_STDERR=$(mktemp)
  ASSESSMENT_EXIT_CODE=0
  if [ "$AUTO_MODE" = true ]; then
    ASSESSMENT_RESULT=$("$RITE_LIB_DIR/core/assess-review-issues.sh" "$PR_NUMBER" "$REVIEW_FILE" --auto 2> >(tee "$ASSESSMENT_STDERR" >&2)) || ASSESSMENT_EXIT_CODE=$?
  else
    ASSESSMENT_RESULT=$("$RITE_LIB_DIR/core/assess-review-issues.sh" "$PR_NUMBER" "$REVIEW_FILE" 2> >(tee "$ASSESSMENT_STDERR" >&2)) || ASSESSMENT_EXIT_CODE=$?
  fi
  # Wait for tee subprocess to finish writing
  wait
  ASSESSMENT_ERROR=$(cat "$ASSESSMENT_STDERR")
  rm -f "$ASSESSMENT_STDERR"

  if [ $ASSESSMENT_EXIT_CODE -eq 0 ] && [ -n "$ASSESSMENT_RESULT" ] && [ "$ASSESSMENT_RESULT" != "ALL_ITEMS" ]; then
    print_success "Smart assessment complete - three-state categorization applied"

    # Parse three-state actionability (keep in variable, no temp file!)
    # IMPORTANT: Match structured headers only (^### Title - STATE) to avoid
    # counting mentions of state names in reasoning text
    ACTIONABLE_NOW_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -c "^### .* - ACTIONABLE_NOW" || true)
    ACTIONABLE_LATER_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -c "^### .* - ACTIONABLE_LATER" || true)
    DISMISSED_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -c "^### .* - DISMISSED" || true)

    # Print detailed assessment breakdown FIRST (shows reasoning for each item)
    print_assessment_details "$ASSESSMENT_RESULT" || {
      print_warning "Could not parse assessment details (format may be unexpected)"
      echo ""
    }

    # Print decision summary AFTER details (acts as summary/TL;DR)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 Assessment Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_status "  • ACTIONABLE_NOW: $ACTIONABLE_NOW_COUNT items (fix in this PR)"
    print_status "  • ACTIONABLE_LATER: $ACTIONABLE_LATER_COUNT items (defer to tech-debt)"
    print_status "  • DISMISSED: $DISMISSED_COUNT items (not worth tracking)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Decision tree based on three-state counts
    if [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -eq 0 ]; then
      print_success "✅ All items dismissed - PR is ready to merge!"

      if [ "$AUTO_MODE" = true ]; then
        print_info "Auto mode: proceeding to merge workflow"
      fi

      exit 0

    elif [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
      # Only ACTIONABLE_LATER items - create tech-debt issue and merge
      print_info "✅ No immediate fixes needed"
      print_status "📝 Creating tech-debt issue for $ACTIONABLE_LATER_COUNT deferred items..."

      # Set flag to create tech-debt issue, then exit 0 to allow merge
      CREATE_SECURITY_DEBT=true
      FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
      # Will create issue below, then exit 0

    elif [ "$ACTIONABLE_NOW_COUNT" -gt 0 ]; then
      # ACTIONABLE_NOW items exist - need to fix them

      # Check retry limit for ACTIONABLE_NOW items
      if [ "$RETRY_COUNT" -ge 3 ]; then
        print_warning "⚠️  At retry limit ($RETRY_COUNT/3) with $ACTIONABLE_NOW_COUNT ACTIONABLE_NOW items remaining"

        # Check if any ACTIONABLE_NOW items are CRITICAL
        CRITICAL_NOW_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -A 2 "^### .* - ACTIONABLE_NOW" | grep -ci "Severity:.*CRITICAL" || true)

        if [ "$CRITICAL_NOW_COUNT" -gt 0 ]; then
          print_critical "🚨 $CRITICAL_NOW_COUNT CRITICAL items remain at retry limit"
          print_error "Cannot merge - blocking issues require manual intervention"
          print_info "Will create follow-up issue and exit with code 1"
          # Set flag to create CRITICAL follow-up issue, then exit 1
          CREATE_CRITICAL_FOLLOWUP=true
          FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
        else
          print_info "✅ No CRITICAL items remain (only HIGH/MEDIUM/LOW)"
          print_status "Creating tech-debt issue for remaining items..."
          # Treat remaining ACTIONABLE_NOW as ACTIONABLE_LATER at retry limit
          CREATE_SECURITY_DEBT=true
          FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
        fi

        # Also handle ACTIONABLE_LATER items if they exist
        if [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
          print_info "Note: $ACTIONABLE_LATER_COUNT ACTIONABLE_LATER items will also be included in tech-debt"
        fi

        # Extract counts from FILTERED_ASSESSMENT for Issue Summary display
        # This ensures counts are populated before the summary is shown
        # Match structured headers (^### Title - STATE) then check severity on next lines
        if [ -n "${FILTERED_ASSESSMENT:-}" ]; then
          _ACTIONABLE_ITEMS=$(echo "$FILTERED_ASSESSMENT" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
          if [ "$_ACTIONABLE_ITEMS" -gt 0 ]; then
            CRITICAL_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*CRITICAL" || true)
            HIGH_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*HIGH" || true)
            MEDIUM_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*MEDIUM" || true)
            LOW_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*LOW" || true)
          fi
          CRITICAL_COUNT=${CRITICAL_COUNT:-0}
          HIGH_COUNT=${HIGH_COUNT:-0}
          MEDIUM_COUNT=${MEDIUM_COUNT:-0}
          LOW_COUNT=${LOW_COUNT:-0}
        fi

      else
        # Normal loop: ACTIONABLE_NOW items exist, retry count < 3
        print_info "🔄 $ACTIONABLE_NOW_COUNT ACTIONABLE_NOW items found - will loop to fix" >&2

        if [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
          print_info "Note: $ACTIONABLE_LATER_COUNT ACTIONABLE_LATER items will be deferred until fixes complete" >&2
        fi

        print_info "Outputting holistic assessment to stdout (pipe-friendly)" >&2

        # Echo the assessment result directly to original stdout (fd 3)
        # This includes both ACTIONABLE_NOW and ACTIONABLE_LATER items
        # claude-workflow.sh will focus on ACTIONABLE_NOW
        echo "$ASSESSMENT_RESULT" >&3

        print_info "Exiting with code 2 to restart PR cycle and fix ACTIONABLE_NOW issues" >&2
        exit 2
      fi
    fi

  else
    print_warning "Smart assessment failed or returned unexpected result"
    if [ -n "$ASSESSMENT_ERROR" ]; then
      echo ""
      echo "Assessment error output:"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "$ASSESSMENT_ERROR"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
    fi
    if [ -n "$ASSESSMENT_RESULT" ]; then
      echo "Assessment result (first 500 chars):"
      echo "${ASSESSMENT_RESULT:0:500}"
      echo ""
    fi
    print_info "Falling back to raw review count for decision"
    # Parse counts from raw review
    CRITICAL_COUNT=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
    CRITICAL_COUNT=${CRITICAL_COUNT:-0}
    HIGH_COUNT=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
    HIGH_COUNT=${HIGH_COUNT:-0}
    MEDIUM_COUNT=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
    MEDIUM_COUNT=${MEDIUM_COUNT:-0}
    LOW_COUNT=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
    LOW_COUNT=${LOW_COUNT:-0}
    ACTIONABLE_COUNT=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))
  fi

else
  print_warning "assess-review-issues.sh not found - treating all issues as actionable"
  # Parse counts from raw review
  CRITICAL_COUNT=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
  CRITICAL_COUNT=${CRITICAL_COUNT:-0}
  HIGH_COUNT=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
  HIGH_COUNT=${HIGH_COUNT:-0}
  MEDIUM_COUNT=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
  MEDIUM_COUNT=${MEDIUM_COUNT:-0}
  LOW_COUNT=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ')
  LOW_COUNT=${LOW_COUNT:-0}
  ACTIONABLE_COUNT=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))
fi

echo ""

# ============================================================================
# DISPLAY ISSUE SUMMARY (after smart assessment has filtered counts)
# ============================================================================

# Initialize counts if not already set (happens when early exit paths are taken)
CRITICAL_COUNT=${CRITICAL_COUNT:-0}
HIGH_COUNT=${HIGH_COUNT:-0}
MEDIUM_COUNT=${MEDIUM_COUNT:-0}
LOW_COUNT=${LOW_COUNT:-0}

TOTAL_ISSUES=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Issue Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_critical "$CRITICAL_COUNT issues - Must fix before merge"
print_high "$HIGH_COUNT issues - Should fix immediately"
print_medium "$MEDIUM_COUNT issues - Create GitHub issues"
print_low "$LOW_COUNT issues - Batch into nice-to-have"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $TOTAL_ISSUES issues"
echo ""

# ============================================================================
# FOLLOW-UP ISSUE CREATION
# Only reached if at retry limit with items remaining
# ============================================================================

# Skip old decision tree if we already handled it above
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "false" ] && [ "${CREATE_SECURITY_DEBT:-false}" = "false" ]; then
  print_info "No follow-up issues needed - assessment handled everything"
  exit 0
fi

# Handle tech-debt case (retry limit reached, no CRITICAL items)
if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
  print_status "Creating tech-debt issue with remaining HIGH/MEDIUM/LOW items..."

  # Use filtered review for tech-debt issue
  FOLLOWUP_LABEL="tech-debt"
  FOLLOWUP_TITLE="Tech Debt: Review feedback from PR #$PR_NUMBER"
  CREATE_FOLLOWUP_ISSUES=true
  CREATE_LOW_BATCH=false  # Items already grouped in filtered review
fi

# Handle critical follow-up case (retry limit reached, CRITICAL items remain)
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "true" ]; then
  print_status "Creating CRITICAL follow-up issue for manual intervention..."

  # Use filtered review for critical follow-up
  FOLLOWUP_LABEL="review-follow-up"
  FOLLOWUP_TITLE="CRITICAL: Review feedback from PR #$PR_NUMBER"
  CREATE_FOLLOWUP_ISSUES=true
  CREATE_LOW_BATCH=false
fi

# Create consolidated follow-up issue if needed
if [ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ]; then
  print_header "📝 Creating Consolidated Follow-up Issue"

  # Check if we already have filtered assessment from earlier smart assessment
  if [ -n "${FILTERED_ASSESSMENT:-}" ]; then
    print_info "Reusing holistic assessment from earlier (no duplicate analysis)"
    FILTERED_CONTENT="$FILTERED_ASSESSMENT"
    USE_FILTERED=true
  else
    USE_FILTERED=false
  fi

  # Extract issues from holistic assessment
  if [ "$USE_FILTERED" = true ] && [ -n "$FILTERED_CONTENT" ]; then
    # Determine which items to include based on issue type
    if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
      print_status "Extracting ACTIONABLE_LATER items for tech-debt issue..."
      CRITICAL_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_LATER" | grep -B2 -A 20 "CRITICAL" || echo "")
      HIGH_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_LATER" | grep -B2 -A 20 "HIGH" || echo "")
      MEDIUM_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_LATER" | grep -B2 -A 20 "MEDIUM" || echo "")
      LOW_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_LATER" | grep -B2 -A 20 "LOW" || echo "")

      if [ "$RETRY_COUNT" -ge 3 ]; then
        print_status "Also including unresolved ACTIONABLE_NOW items (retry limit reached)..."
        CRITICAL_ISSUES="$CRITICAL_ISSUES
$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_NOW" | grep -B2 -A 20 "CRITICAL" || echo "")"
        HIGH_ISSUES="$HIGH_ISSUES
$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_NOW" | grep -B2 -A 20 "HIGH" || echo "")"
        MEDIUM_ISSUES="$MEDIUM_ISSUES
$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_NOW" | grep -B2 -A 20 "MEDIUM" || echo "")"
        LOW_ISSUES="$LOW_ISSUES
$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE_NOW" | grep -B2 -A 20 "LOW" || echo "")"
      fi
    else
      CRITICAL_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE" | grep -B2 -A 20 "CRITICAL" || echo "")
      HIGH_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE" | grep -B2 -A 20 "HIGH" || echo "")
      MEDIUM_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE" | grep -B2 -A 20 "MEDIUM" || echo "")
      LOW_ISSUES=$(echo "$FILTERED_CONTENT" | grep -B2 -A 20 "ACTIONABLE" | grep -B2 -A 20 "LOW" || echo "")
    fi

    # Recount after filtering (grep -c returns exit 1 on no match but still outputs "0")
    CRITICAL_COUNT=$(echo "$CRITICAL_ISSUES" | grep -c -E "ACTIONABLE_(NOW|LATER)" 2>/dev/null) || true
    HIGH_COUNT=$(echo "$HIGH_ISSUES" | grep -c -E "ACTIONABLE_(NOW|LATER)" 2>/dev/null) || true
    MEDIUM_COUNT=$(echo "$MEDIUM_ISSUES" | grep -c -E "ACTIONABLE_(NOW|LATER)" 2>/dev/null) || true
    LOW_COUNT=$(echo "$LOW_ISSUES" | grep -c -E "ACTIONABLE_(NOW|LATER)" 2>/dev/null) || true
    # Ensure numeric defaults
    CRITICAL_COUNT=${CRITICAL_COUNT:-0}
    HIGH_COUNT=${HIGH_COUNT:-0}
    MEDIUM_COUNT=${MEDIUM_COUNT:-0}
    LOW_COUNT=${LOW_COUNT:-0}

    print_info "Issue counts: CRITICAL=$CRITICAL_COUNT, HIGH=$HIGH_COUNT, MEDIUM=$MEDIUM_COUNT, LOW=$LOW_COUNT"
  else
    # Fallback: Extract all issues from review using sed (when Claude unavailable)
    CRITICAL_ISSUES=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    HIGH_ISSUES=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    MEDIUM_ISSUES=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    LOW_ISSUES=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
  fi

  # Build consolidated issue body
  ASSESSMENT_NOTE=""
  if [ "$USE_FILTERED" = true ]; then
    if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
      ASSESSMENT_NOTE="

> 🤖 **Three-State Assessment Applied**: Items below are categorized as **ACTIONABLE_LATER** - valid improvements deferred due to scope constraints or time limits.
>
> - ✅ **DISMISSED**: Style preferences and over-engineering were filtered out
> - ⏭️  **ACTIONABLE_LATER**: These improvements align with project goals but exceed current PR scope or time constraints
> - 📋 **Why deferred?**: See 'Defer Reason' in each item for context"
    else
      ASSESSMENT_NOTE="

> 🦈 **Smart Assessment Applied**: Issues below have been filtered by Sharkrite's three-state categorization. Only items deemed **ACTIONABLE** are included (either NOW or LATER). Opinionated style preferences have been dismissed."
    fi
  fi

  # Determine issue type and title
  if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
    FOLLOWUP_TITLE_PREFIX="Security Debt"
    FOLLOWUP_DESCRIPTION="This issue tracks valid improvements that were deferred due to scope or time constraints. These are NOT blocking issues, but should be addressed when capacity allows."
  else
    FOLLOWUP_TITLE_PREFIX="Review Follow-up"
    FOLLOWUP_DESCRIPTION="This issue consolidates all review feedback items that should be addressed. Items are grouped by priority."
  fi

  # Build follow-up issue body using the structure from templates/issue-template.md.
  # Sections: Description, Claude Context, Acceptance Criteria, Done Definition,
  # Scope Boundary, Dependencies, Time Estimate.

  # --- Gather data for template sections ---

  # Claude Context: extract changed file paths from the PR
  CHANGED_FILES=$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null || echo "")
  CLAUDE_CONTEXT=""
  if [ -n "$CHANGED_FILES" ]; then
    CLAUDE_CONTEXT=$(echo "$CHANGED_FILES" | sed 's/^/- `/' | sed 's/$/`/')
  fi

  # Acceptance Criteria: extract item titles and severities from assessment headers
  ACCEPTANCE_ITEMS=""
  if [ -n "${FILTERED_CONTENT:-}" ]; then
    # Parse "### Title - ACTIONABLE_NOW" or "### Title - ACTIONABLE_LATER" headers
    # Use process substitution to avoid subshell variable loss
    while IFS= read -r _ac_line; do
      _ac_title=$(echo "$_ac_line" | sed 's/^### //; s/ - ACTIONABLE_.*//')
      # Look up severity for this item (lines after the header in assessment)
      _ac_severity=$(echo "$FILTERED_CONTENT" | grep -A 3 -F "$_ac_line" | grep -oE "Severity:.*" | head -1 | sed 's/Severity:[[:space:]]*//' | sed 's/\*//g')
      _ac_severity=${_ac_severity:-MEDIUM}
      ACCEPTANCE_ITEMS="${ACCEPTANCE_ITEMS}
- [ ] [$_ac_severity] $_ac_title"
    done < <(echo "$FILTERED_CONTENT" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)
    # Trim leading newline
    ACCEPTANCE_ITEMS=$(echo "$ACCEPTANCE_ITEMS" | sed '/^$/d')
  fi
  # Fallback if no items extracted
  if [ -z "$ACCEPTANCE_ITEMS" ]; then
    ACCEPTANCE_ITEMS="- [ ] Address all CRITICAL/HIGH priority issues
- [ ] Address MEDIUM priority issues
- [ ] Consider LOW priority suggestions"
  fi

  # Done Definition: based on severity mix
  if [ "$CRITICAL_COUNT" -gt 0 ]; then
    DONE_DEFINITION="All CRITICAL and HIGH items resolved and verified; MEDIUM/LOW addressed or explicitly deferred with justification."
  elif [ "$HIGH_COUNT" -gt 0 ]; then
    DONE_DEFINITION="All HIGH items resolved and verified; MEDIUM/LOW addressed or deferred with justification."
  else
    DONE_DEFINITION="All MEDIUM items addressed; LOW items considered and deferred if not applicable."
  fi

  # Time Estimate: aggregate from Fix Effort metadata if available
  TIME_ESTIMATE=""
  if [ -n "${FILTERED_CONTENT:-}" ]; then
    effort_10min=$(echo "$FILTERED_CONTENT" | grep -c "Fix Effort:.*<10min" || true)
    effort_1hr=$(echo "$FILTERED_CONTENT" | grep -c "Fix Effort:.*<1hr" || true)
    effort_gt1hr=$(echo "$FILTERED_CONTENT" | grep -c "Fix Effort:.*>1hr" || true)
    if [ "$effort_gt1hr" -gt 0 ]; then
      TIME_ESTIMATE="4hr"
    elif [ "$effort_1hr" -gt 1 ]; then
      TIME_ESTIMATE="2hr"
    elif [ "$effort_1hr" -gt 0 ] || [ "$effort_10min" -gt 2 ]; then
      TIME_ESTIMATE="1hr"
    elif [ "$effort_10min" -gt 0 ]; then
      TIME_ESTIMATE="30min"
    fi
  fi

  # PR metadata
  PR_BRANCH_NAME=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "unknown")

  # --- Build issue body ---

  FOLLOWUP_BODY="## Description

$FOLLOWUP_DESCRIPTION$ASSESSMENT_NOTE

**Source PR:** #$PR_NUMBER
**Branch:** $PR_BRANCH_NAME
**Review Date:** $(date +%Y-%m-%d)

---

### 🚨 CRITICAL Security Issues ($CRITICAL_COUNT)

$(if [ "$CRITICAL_COUNT" -gt 0 ]; then echo "$CRITICAL_ISSUES"; else echo "_No CRITICAL issues_"; fi)

---

### 🔴 HIGH Priority Issues ($HIGH_COUNT)

$(if [ "$HIGH_COUNT" -gt 0 ]; then echo "$HIGH_ISSUES"; else echo "_No HIGH priority issues_"; fi)

---

### 🟡 MEDIUM Priority Issues ($MEDIUM_COUNT)

$(if [ "$MEDIUM_COUNT" -gt 0 ]; then echo "$MEDIUM_ISSUES"; else echo "_No MEDIUM priority issues_"; fi)

---

### 🟢 LOW Priority / Nice-to-Have ($LOW_COUNT)

$(if [ "$LOW_COUNT" -gt 0 ]; then echo "$LOW_ISSUES"; else echo "_No LOW priority issues_"; fi)

## Claude Context
Files to read before starting:
$CLAUDE_CONTEXT

## Acceptance Criteria
$ACCEPTANCE_ITEMS
- [ ] Verify fixes with tests
- [ ] Update documentation if applicable

## Done Definition
$DONE_DEFINITION

## Scope Boundary
- DO: Address the specific review findings listed above
- DO NOT: Refactor surrounding code, add new features, or modify unrelated files

## Dependencies
After: #${ISSUE_NUMBER:-$PR_NUMBER}
$([ -n "${TIME_ESTIMATE:-}" ] && echo "
## Time Estimate
$TIME_ESTIMATE" || echo "")

---

_Auto-generated follow-up from PR #$PR_NUMBER review_"

  # Determine issue title and search term based on type
  # Title format follows templates/issue-template.md convention: [type] Brief description
  if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
    ISSUE_TITLE="[tech-debt] Review feedback from PR #$PR_NUMBER"
    ISSUE_SEARCH="Review feedback from PR #$PR_NUMBER"
  else
    ISSUE_TITLE="[review-follow-up] Review feedback from PR #$PR_NUMBER"
    ISSUE_SEARCH="Review feedback from PR #$PR_NUMBER"
  fi

  # Check if issue already exists for this PR
  EXISTING_ISSUE=$(gh issue list --search "in:title $ISSUE_SEARCH" --json number,title,state --limit 1 | \
    jq -r '.[] | select(.state == "OPEN") | .number' 2>/dev/null || echo "")

  if [ -n "$EXISTING_ISSUE" ]; then
    echo ""
    print_success "📋 Follow-up issue already exists: #$EXISTING_ISSUE"
    print_info "Skipping duplicate issue creation"
    issue_url=$(gh issue view "$EXISTING_ISSUE" --json url --jq '.url' 2>/dev/null || echo "")
    echo "  URL: $issue_url"
    echo ""

    # Set FOLLOWUP_NUMBER so caller knows issue exists
    FOLLOWUP_NUMBER="$EXISTING_ISSUE"
  else
    # Determine label type based on context and severity
    if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
      ISSUE_LABELS="tech-debt,parent-pr:$PR_NUMBER"
    elif [ "$CRITICAL_COUNT" -gt 0 ]; then
      ISSUE_LABELS="review-follow-up,parent-pr:$PR_NUMBER"
    else
      ISSUE_LABELS="tech-debt,parent-pr:$PR_NUMBER"
    fi

    # Add priority labels based on highest severity
    if [ "$HIGH_COUNT" -gt 0 ]; then
      ISSUE_LABELS="$ISSUE_LABELS,High Priority"
    elif [ "$MEDIUM_COUNT" -gt 0 ]; then
      ISSUE_LABELS="$ISSUE_LABELS,Medium Priority"
    else
      ISSUE_LABELS="$ISSUE_LABELS,enhancement"
    fi

    # Create consolidated follow-up issue
    FOLLOWUP_ISSUE=""
    if FOLLOWUP_ISSUE=$(gh issue create \
      --title "$ISSUE_TITLE" \
      --body "$FOLLOWUP_BODY" \
      --label "$ISSUE_LABELS" \
      2>&1); then
      FOLLOWUP_NUMBER=$(echo "$FOLLOWUP_ISSUE" | grep -oE '[0-9]+$' || echo "")
      echo ""
      print_success "✅ Follow-up issue created: #$FOLLOWUP_NUMBER"
      echo "  URL: $FOLLOWUP_ISSUE"
      echo "  Type: ${CREATE_SECURITY_DEBT:+Tech Debt}${CREATE_SECURITY_DEBT:-Review Follow-up}"
      echo "  Items: NOW=${ACTIONABLE_NOW_COUNT:-0}, LATER=${ACTIONABLE_LATER_COUNT:-0} (total in issue)"
      echo ""

      # Comment on PR with link to follow-up (includes machine-readable marker for workflow detection)
      COMMENT_BODY="<!-- sharkrite-followup-issue:$FOLLOWUP_NUMBER -->
📋 **Consolidated follow-up issue created:** #$FOLLOWUP_NUMBER

All review feedback has been grouped into a single issue for batch processing:
- 🔴 HIGH priority: $HIGH_COUNT
- 🟡 MEDIUM priority: $MEDIUM_COUNT
- 🟢 LOW priority: $LOW_COUNT

This approach allows all fixes to be completed together in a focused PR."

      gh pr comment "$PR_NUMBER" --body "$COMMENT_BODY" 2>/dev/null || true
    else
      print_warning "Failed to create consolidated follow-up issue"
    fi
  fi

  # Auto-queue batch processing if not already in batch mode
  if [ -n "${FOLLOWUP_NUMBER:-}" ] && [ -z "${BATCH_MODE:-}" ]; then
    print_header "🚀 Handing Off to Batch Workflow"

    # Find original issue that created this PR
    ORIGINAL_ISSUE=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null | grep -oE 'Closes #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")

    print_success "Follow-up issue #$FOLLOWUP_NUMBER ready for batch processing"
    echo ""
    print_info "Workflow plan:"
    print_status "  1. Fix issues in #$FOLLOWUP_NUMBER → update PR #$PR_NUMBER"
    print_status "  2. Wait for new review (up to 15 minutes)"
    print_status "  3. Merge #$ORIGINAL_ISSUE if review passes"
    echo ""
    print_status "Transitioning to batch workflow..."
    echo ""

    # EXEC into batch processor (replaces current process)
    exec "$RITE_LIB_DIR/core/batch-process-issues.sh" "$FOLLOWUP_NUMBER" "$ORIGINAL_ISSUE" --auto --smart-wait
  elif [ -n "${BATCH_MODE:-}" ]; then
    print_info "In batch mode - skipping auto-queue (prevents recursion)"
  fi
fi

# Final summary
print_header "✅ Assessment Complete"

if [ "$CRITICAL_COUNT" -eq 0 ] && [ "$HIGH_COUNT" -eq 0 ] && [ "$MEDIUM_COUNT" -eq 0 ] && [ "$LOW_COUNT" -eq 0 ]; then
  print_success "No issues found - PR approved!"
  echo ""
  echo "Ready to merge"
  exit 0
fi

echo "Summary of actions taken:"
[ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ] && [ -n "${FOLLOWUP_NUMBER:-}" ] && echo "  ✅ Follow-up issue #$FOLLOWUP_NUMBER created for HIGH/MEDIUM items"
[ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ] && [ -z "${FOLLOWUP_NUMBER:-}" ] && echo "  ⚠️  Follow-up issue creation failed (items not tracked)"
[ "${CREATE_LOW_BATCH:-false}" = true ] && [ "$LOW_COUNT" -gt 0 ] && echo "  ✅ Batched LOW priority items into single issue"
[ "$CRITICAL_COUNT" -eq 0 ] && [ "$HIGH_COUNT" -eq 0 ] && echo "  ✅ No blocking issues - safe to merge"

echo ""

if [ "$CRITICAL_COUNT" -eq 0 ]; then
  print_success "All issues resolved or tracked - ready to proceed"
  exit 0
else
  print_error "CRITICAL issues require fixes"
  exit 2
fi
