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
source "$RITE_LIB_DIR/utils/labels.sh"
source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/issue-lock.sh"

# Source PR detection for shared commit timestamp utility
source "$RITE_LIB_DIR/utils/pr-detection.sh"

# Redirect all display output to stderr (stdout reserved for filtered content on exit 2)
exec 3>&1  # Save original stdout for filtered content output
exec 1>&2  # Redirect stdout to stderr for all print functions

# Log unexpected exits for diagnostics (log-only, not visible in terminal)
trap '_diag "ASSESS_RESOLVE_ERR exit=$? line=$LINENO"' ERR

# Temp file cleanup trap handler (minimal - only for initial review fetch)
cleanup() {
  local exit_code=$?
  # Clean up minimal temp files on exit
  # Note: REVIEW_FILE is kept minimal (only for initial gh pr view)
  # All assessment data flows through variables/pipes (no temp files)
  rm -f /tmp/pr_review_*.txt 2>/dev/null || true
  # Release follow-up lock on signal (SIGINT/SIGTERM) to avoid leaving it
  # held for the full 60s acquire-loop timeout on the next run.
  # Pass ISSUE_NUMBER (if set) to release the correct compound lock key.
  if [ "${_followup_lock_held:-false}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    release_pr_followup_lock "$PR_NUMBER" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    _followup_lock_held=false
  fi
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

    # Parse each item (pure awk — no system() calls to avoid shell injection
    # from backticks/quotes in Claude's reasoning text)
    echo "$assessment_content" | awk '
      function wrap(prefix, text, width,    words, n, line, i, indent) {
        indent = "            "
        n = split(text, words, " ")
        line = prefix
        for (i = 1; i <= n; i++) {
          if (length(line) + length(words[i]) + 1 > width && line != prefix) {
            print line
            line = indent words[i]
          } else if (line == prefix) {
            line = line words[i]
          } else {
            line = line " " words[i]
          }
        }
        if (line != "") print line
      }
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
        wrap("    Reason: ", reasoning, 76)
        next
      }
      in_item && /^\*\*Location:\*\*/ {
        location = $0
        gsub(/^\*\*Location:\*\* /, "", location)
        printf "    Location: %s\n", location
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
      function wrap(prefix, text, width,    words, n, line, i, indent) {
        indent = "            "
        n = split(text, words, " ")
        line = prefix
        for (i = 1; i <= n; i++) {
          if (length(line) + length(words[i]) + 1 > width && line != prefix) {
            print line
            line = indent words[i]
          } else if (line == prefix) {
            line = line words[i]
          } else {
            line = line " " words[i]
          }
        }
        if (line != "") print line
      }
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
        wrap("    Reason: ", reasoning, 76)
        next
      }
      in_item && /^\*\*Defer Reason:\*\*/ {
        defer = $0
        gsub(/^\*\*Defer Reason:\*\* /, "", defer)
        wrap("    Defer: ", defer, 76)
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
      function wrap(prefix, text, width,    words, n, line, i, indent) {
        indent = "            "
        n = split(text, words, " ")
        line = prefix
        for (i = 1; i <= n; i++) {
          if (length(line) + length(words[i]) + 1 > width && line != prefix) {
            print line
            line = indent words[i]
          } else if (line == prefix) {
            line = line words[i]
          } else {
            line = line " " words[i]
          }
        }
        if (line != "") print line
      }
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
        wrap("    Reason: ", reasoning, 76)
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
  iso_to_local_display "$iso_timestamp"
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
REVIEW_JSON=$(gh pr view "$PR_NUMBER" --json comments --jq '[.comments[] | select(.body | contains("<!-- sharkrite-local-review"))] | sort_by(.createdAt) | reverse | .[0]' 2>"$GH_STDERR") || {
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
  local model=$(echo "$review_body" | grep -oE 'sharkrite-local-review model:[a-z0-9-]+' | sed 's/.*model://' | head -1 || true)
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
  COMMIT_EPOCH=$(iso_to_epoch "$LATEST_COMMIT_TIME")
  REVIEW_EPOCH=$(iso_to_epoch "$REVIEW_TIME")

  if [ "$COMMIT_EPOCH" -gt "$REVIEW_EPOCH" ]; then
    print_warning "Review is stale — commits pushed after review"
    echo "  Review created: $REVIEW_TIME"
    echo "  Latest commit:  $LATEST_COMMIT_TIME"
    echo ""

    # Check if there's a newer review we missed (match only actual review comments)
    ALL_REVIEWS=$(gh pr view "$PR_NUMBER" --json comments --jq '[.comments[] | select(.body | contains("<!-- sharkrite-local-review"))] | sort_by(.createdAt) | reverse' 2>/dev/null)

    # Compare using epoch seconds (not jq string comparison) for reliable cross-format matching
    NEWER_REVIEW_COUNT=$(echo "$ALL_REVIEWS" | jq '[.[] | .createdAt] | map(sub("Z$";"") | split("T") | .[0] + "T" + .[1]) | map(. > "'"$LATEST_COMMIT_TIME"'" | if . then 1 else 0 end) | add // 0' 2>/dev/null || echo "0")
    # Fallback: use the already-computed COMMIT_EPOCH for a proper epoch comparison
    if [ "$NEWER_REVIEW_COUNT" -eq 0 ] && [ -n "$ALL_REVIEWS" ]; then
      # Check the newest review's createdAt against commit epoch
      _newest_review_time=$(echo "$ALL_REVIEWS" | jq -r '.[0].createdAt // ""' 2>/dev/null)
      if [ -n "$_newest_review_time" ]; then
        _newest_epoch=$(iso_to_epoch "$_newest_review_time")
        if [ "$_newest_epoch" -gt "$COMMIT_EPOCH" ]; then
          NEWER_REVIEW_COUNT=1
        fi
      fi
    fi

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
  REVIEW_TOTAL_FINDINGS=$(echo "$REVIEW_FINDINGS_LINE" | grep -oE "[0-9]+" | awk '{sum += $1} END {print sum}' || true)
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
  # Export source issue number so assess-review-issues.sh can scope dedup searches
  export RITE_ISSUE_NUMBER="${ISSUE_NUMBER:-}"
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
    print_status "  • ACTIONABLE_NOW: $ACTIONABLE_NOW_COUNT items (fix now)"
    print_status "  • ACTIONABLE_LATER: $ACTIONABLE_LATER_COUNT items (defer to tech-debt)"
    print_status "  • DISMISSED: $DISMISSED_COUNT items (not worth tracking)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Diagnostic logging for health reports
    _diag "ASSESSMENT issue=${ISSUE_NUMBER} retry=${RETRY_COUNT} now=${ACTIONABLE_NOW_COUNT} later=${ACTIONABLE_LATER_COUNT} dismissed=${DISMISSED_COUNT}"

    # Decision tree based on three-state counts
    if [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -eq 0 ]; then
      print_success "All items dismissed — ready to merge!"

      exit 0

    elif [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
      # Only ACTIONABLE_LATER items - create tech-debt issue and merge
      print_info "✅ No immediate fixes needed"
      print_status "Creating tech-debt issue for $ACTIONABLE_LATER_COUNT deferred items..."

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
    CRITICAL_COUNT=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    CRITICAL_COUNT=${CRITICAL_COUNT:-0}
    HIGH_COUNT=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    HIGH_COUNT=${HIGH_COUNT:-0}
    MEDIUM_COUNT=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    MEDIUM_COUNT=${MEDIUM_COUNT:-0}
    LOW_COUNT=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    LOW_COUNT=${LOW_COUNT:-0}
    ACTIONABLE_COUNT=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))
  fi

else
  print_warning "assess-review-issues.sh not found - treating all issues as actionable"
  # Parse counts from raw review
  CRITICAL_COUNT=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  CRITICAL_COUNT=${CRITICAL_COUNT:-0}
  HIGH_COUNT=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  HIGH_COUNT=${HIGH_COUNT:-0}
  MEDIUM_COUNT=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  MEDIUM_COUNT=${MEDIUM_COUNT:-0}
  LOW_COUNT=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
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
# Reached when ACTIONABLE_LATER items need tech-debt issues, or
# when retry limit is hit with remaining ACTIONABLE_NOW/CRITICAL items.
# ============================================================================

# Skip old decision tree if we already handled it above
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "false" ] && [ "${CREATE_SECURITY_DEBT:-false}" = "false" ]; then
  print_info "No follow-up issues needed - assessment handled everything"
  exit 0
fi

# Determine the merge decision NOW, before follow-up issue creation.
# Follow-up creation is best-effort — if it crashes (gh API error, network issue),
# it must NOT override the merge decision. The CREATE_SECURITY_DEBT path means
# "no ACTIONABLE_NOW items, ready to merge" — a failed `gh issue create` shouldn't
# turn that into "assessment failed, block merge."
MERGE_EXIT_CODE=0
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "true" ]; then
  # CRITICAL items at retry limit — genuinely cannot merge
  MERGE_EXIT_CODE=1
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
# Disable errexit: follow-up issue creation is best-effort and must not
# override the merge decision (MERGE_EXIT_CODE) if any gh/grep/jq call fails.
set +e
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
    # Match structured headers first (^### Title - STATE), then check Severity: metadata
    # within those blocks (not bare keywords that could appear in reasoning text)
    if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
      print_status "Extracting ACTIONABLE_LATER items for tech-debt issue..."
      CRITICAL_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*CRITICAL" || echo "")
      HIGH_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*HIGH" || echo "")
      MEDIUM_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*MEDIUM" || echo "")
      LOW_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*LOW" || echo "")

      if [ "$RETRY_COUNT" -ge 3 ]; then
        print_status "Also including unresolved ACTIONABLE_NOW items (retry limit reached)..."
        CRITICAL_ISSUES="$CRITICAL_ISSUES
$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_NOW" | grep -B 2 "Severity:.*CRITICAL" || echo "")"
        HIGH_ISSUES="$HIGH_ISSUES
$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_NOW" | grep -B 2 "Severity:.*HIGH" || echo "")"
        MEDIUM_ISSUES="$MEDIUM_ISSUES
$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_NOW" | grep -B 2 "Severity:.*MEDIUM" || echo "")"
        LOW_ISSUES="$LOW_ISSUES
$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_NOW" | grep -B 2 "Severity:.*LOW" || echo "")"
      fi
    else
      CRITICAL_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -B 2 "Severity:.*CRITICAL" || echo "")
      HIGH_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -B 2 "Severity:.*HIGH" || echo "")
      MEDIUM_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -B 2 "Severity:.*MEDIUM" || echo "")
      LOW_ISSUES=$(echo "$FILTERED_CONTENT" | grep -A 20 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -B 2 "Severity:.*LOW" || echo "")
    fi

    # Recount after filtering - count structured headers (^### Title - STATE)
    # not bare keywords that could match reasoning text
    CRITICAL_COUNT=$(echo "$CRITICAL_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    HIGH_COUNT=$(echo "$HIGH_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    MEDIUM_COUNT=$(echo "$MEDIUM_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    LOW_COUNT=$(echo "$LOW_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    # Ensure numeric defaults
    CRITICAL_COUNT=${CRITICAL_COUNT:-0}
    HIGH_COUNT=${HIGH_COUNT:-0}
    MEDIUM_COUNT=${MEDIUM_COUNT:-0}
    LOW_COUNT=${LOW_COUNT:-0}

    print_info "Issue counts: CRITICAL=$CRITICAL_COUNT, HIGH=$HIGH_COUNT, MEDIUM=$MEDIUM_COUNT, LOW=$LOW_COUNT"

    # Drop LOW items — they accumulate noise without justifying issue overhead.
    # Log them for visibility but exclude from the follow-up issue.
    if [ "$LOW_COUNT" -gt 0 ]; then
      print_info "Excluding $LOW_COUNT LOW-severity item(s) from follow-up issue (not worth tracking)"
    fi
    LOW_ISSUES=""
    LOW_COUNT=0
  else
    # Fallback: Extract all issues from review using sed (when Claude unavailable)
    CRITICAL_ISSUES=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    HIGH_ISSUES=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    MEDIUM_ISSUES=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    LOW_ISSUES=""
    LOW_COUNT=0
  fi

  # If only LOWs existed and we just filtered them all out, skip issue creation
  if [ "$CRITICAL_COUNT" -eq 0 ] && [ "$HIGH_COUNT" -eq 0 ] && [ "$MEDIUM_COUNT" -eq 0 ]; then
    print_info "All remaining items are LOW severity — skipping follow-up issue creation"
    CREATE_FOLLOWUP_ISSUES=false
  fi
fi

# Gate: only proceed if we still have items worth tracking after LOW filtering
if [ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ]; then
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
      _ac_severity=$(echo "$FILTERED_CONTENT" | grep -A 3 -F "$_ac_line" | grep -oE "Severity:.*" | head -1 | sed 's/Severity:[[:space:]]*//' | sed 's/\*//g' || true)
      _ac_severity=${_ac_severity:-MEDIUM}
      # Skip LOW items — excluded from follow-up issues
      if echo "$_ac_severity" | grep -qi "LOW"; then continue; fi
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
  PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq '.title' 2>/dev/null || echo "")

  # --- Build issue body ---

  SOURCE_ISSUE_MARKER=""
  [ -n "${ISSUE_NUMBER:-}" ] && SOURCE_ISSUE_MARKER="<!-- sharkrite-source-issue:${ISSUE_NUMBER} -->"
  FOLLOWUP_BODY="${SOURCE_ISSUE_MARKER}<!-- sharkrite-parent-pr:${PR_NUMBER} -->
## Description

$FOLLOWUP_DESCRIPTION$ASSESSMENT_NOTE

**Source PR:** #$PR_NUMBER$([ -n "$PR_TITLE" ] && echo " — $PR_TITLE")
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
  # Include PR title for domain context (e.g., "[tech-debt] Grocery filtering: review feedback from PR #132")
  _pr_context=""
  if [ -n "${PR_TITLE:-}" ]; then
    # Truncate long PR titles to keep issue title under ~80 chars
    _pr_context=$(echo "$PR_TITLE" | cut -c1-50 | sed 's/[[:space:]]*$//')
    [ ${#PR_TITLE} -gt 50 ] && _pr_context="${_pr_context}..."
    _pr_context="${_pr_context}: "
  fi
  # When a source issue number is known, include it in both the title and the search
  # key so that two distinct source-issue follow-ups for the same PR get unique titles
  # and independent dedup scopes.  Without this, a title-search fallback for PR #N
  # would find the first source-issue's follow-up and incorrectly skip creating the
  # second source-issue's follow-up (1-PR→multiple-source-issues scenario).
  _src_issue_suffix=""
  [ -n "${ISSUE_NUMBER:-}" ] && _src_issue_suffix=" for issue #${ISSUE_NUMBER}"

  if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
    ISSUE_TITLE="[tech-debt] ${_pr_context}review feedback from PR #$PR_NUMBER${_src_issue_suffix}"
    ISSUE_SEARCH="review feedback from PR #$PR_NUMBER${_src_issue_suffix}"
  else
    ISSUE_TITLE="[review-follow-up] ${_pr_context}review feedback from PR #$PR_NUMBER${_src_issue_suffix}"
    ISSUE_SEARCH="review feedback from PR #$PR_NUMBER${_src_issue_suffix}"
  fi

  # Acquire per-PR follow-up lock before the check-then-create sequence.
  #
  # Without this lock, two concurrent assess-and-resolve calls on the same PR can
  # both pass the dedup search (GitHub API eventual consistency means the first
  # created issue is not yet indexed) and create duplicate follow-up issues.
  # The lock serialises the critical section.
  #
  # Lock timeout (exit 1) means a live process held the lock for 60+ seconds —
  # this indicates genuine concurrent contention, which is precisely the race we
  # are preventing.  Proceeding without the lock (fail-open) would defeat the
  # entire purpose of this PR.  Instead we fail-closed: log and skip creation so
  # the caller can retry rather than risk a duplicate.
  # Pass ISSUE_NUMBER as the second arg so the lock is keyed by PR + source issue.
  # This ensures that two concurrent invocations for DIFFERENT source issues on the
  # same PR operate on independent locks (no false blocking) and independent dedup
  # search scopes (no false "already exists" detection).
  _followup_lock_held=false
  if acquire_pr_followup_lock "$PR_NUMBER" "${ISSUE_NUMBER:-}" 2>/dev/null; then
    _followup_lock_held=true
  else
    _lock_scope="PR #$PR_NUMBER${ISSUE_NUMBER:+ / issue #$ISSUE_NUMBER}"
    print_warning "Could not acquire follow-up lock for ${_lock_scope} after 60s — another process is still in the critical section."
    print_warning "Skipping follow-up issue creation to prevent duplicates. Re-run assess-and-fix if needed."
    _skip_followup_creation=true
  fi

  if [ "${_skip_followup_creation:-false}" != "true" ]; then

  # Check if issue already exists.  Four evidence sources checked in order of
  # reliability and cost:
  #
  #   1. Local evidence file (fastest, no network, survives PR comment failures)
  #   2. Body-marker search scoped to source issue (reliable when indexed)
  #   3. Title search (catches cases where body marker not yet indexed)
  #   4. PR marker comment (guards against index lag after another process created)
  #
  # Source 1 (local evidence) is the fix for the edge case where the GitHub PR
  # comment write fails (||true silences it) and both the issue body and title
  # searches miss due to index lag.  The evidence file is written to disk while
  # the lock is held, so it is guaranteed to be present if any prior holder of
  # this lock successfully created an issue — even if the comment write failed.
  EXISTING_ISSUE=""
  _dedup_retries=0
  _dedup_max_retries=3
  _dedup_backoff=5  # seconds between retries

  while [ "$_dedup_retries" -le "$_dedup_max_retries" ]; do
    EXISTING_ISSUE=""

    # Source 1: local evidence file — no API call, survives comment-write failures
    EXISTING_ISSUE=$(read_followup_evidence "$PR_NUMBER" "${ISSUE_NUMBER:-}" || true)

    # Validate that the locally-evidenced issue is still open.  The evidence file
    # persists indefinitely; if the referenced issue was closed or deleted since it
    # was written, trusting it would permanently suppress recreation of the follow-up.
    if [ -n "$EXISTING_ISSUE" ]; then
      _evidence_issue_state=$(gh issue view "$EXISTING_ISSUE" --json state --jq '.state' 2>/dev/null || true)
      if [ "${_evidence_issue_state}" != "OPEN" ]; then
        print_info "Local evidence points to issue #$EXISTING_ISSUE (state: ${_evidence_issue_state:-unknown}) — removing stale evidence file and continuing dedup check"
        clear_followup_evidence "$PR_NUMBER" "${ISSUE_NUMBER:-}"
        EXISTING_ISSUE=""
      fi
    fi

    # Source 2: body-marker search scoped to source issue (most reliable when indexed)
    if [ -z "$EXISTING_ISSUE" ] && [ -n "${ISSUE_NUMBER:-}" ]; then
      EXISTING_ISSUE=$(gh issue list \
        --state open \
        --search "sharkrite-source-issue:${ISSUE_NUMBER} in:body" \
        --json number \
        --jq '.[0].number' 2>/dev/null | grep -E '^[0-9]+$' || true)
    fi

    # Source 3: title search (catches cases where body marker not yet indexed)
    if [ -z "$EXISTING_ISSUE" ]; then
      EXISTING_ISSUE=$(gh issue list --search "in:title $ISSUE_SEARCH" --json number,title,state --limit 1 | \
        jq -r '.[] | select(.state == "OPEN") | .number' 2>/dev/null || true)
    fi

    # If found by any source, no need to retry
    [ -n "$EXISTING_ISSUE" ] && break

    # Source 4: PR marker comment — if the comment was posted by a prior run
    # but neither local evidence nor the search index has caught up yet,
    # back off and retry rather than creating a duplicate.
    if [ "$_dedup_retries" -lt "$_dedup_max_retries" ]; then
      _recent_followup_comment=$(gh pr view "$PR_NUMBER" \
        --json comments \
        --jq '[.comments[].body | select(contains("<!-- sharkrite-followup-issue:"))] | length' \
        2>/dev/null || echo "0")
      if [ "${_recent_followup_comment:-0}" -gt 0 ]; then
        _dedup_retries=$((_dedup_retries + 1))
        print_info "Follow-up comment found on PR but issue not yet indexed (attempt $_dedup_retries/$_dedup_max_retries) — retrying in ${_dedup_backoff}s..."
        sleep "$_dedup_backoff"
        continue
      fi
    fi

    # No evidence of prior creation — break and proceed to create
    break
  done

  if [ -n "$EXISTING_ISSUE" ]; then
    # Release lock before any output — we won't be creating an issue
    [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    _followup_lock_held=false

    echo ""
    print_success "📋 Follow-up issue already exists: #$EXISTING_ISSUE (skipping duplicate)"
    issue_url=$(gh issue view "$EXISTING_ISSUE" --json url --jq '.url' 2>/dev/null || echo "")
    echo "  URL: $issue_url"
    echo ""

    # Set FOLLOWUP_NUMBER so caller knows issue exists
    FOLLOWUP_NUMBER="$EXISTING_ISSUE"
  else
    # Determine label type based on context and severity
    if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
      ISSUE_LABELS="tech-debt"
    elif [ "$CRITICAL_COUNT" -gt 0 ]; then
      ISSUE_LABELS="review-follow-up"
    else
      ISSUE_LABELS="tech-debt"
    fi

    # Add priority labels based on highest severity
    if [ "$HIGH_COUNT" -gt 0 ]; then
      ISSUE_LABELS="$ISSUE_LABELS,High Priority"
    elif [ "$MEDIUM_COUNT" -gt 0 ]; then
      ISSUE_LABELS="$ISSUE_LABELS,Medium Priority"
    else
      ISSUE_LABELS="$ISSUE_LABELS,enhancement"
    fi

    # Ensure all required labels exist (create missing ones rather than failing)
    ensure_labels_exist "$ISSUE_LABELS"

    # Create consolidated follow-up issue (via temp file to avoid shell metacharacter issues)
    FOLLOWUP_BODY_FILE=$(mktemp)
    printf '%s' "$FOLLOWUP_BODY" > "$FOLLOWUP_BODY_FILE"
    FOLLOWUP_ISSUE=""
    if FOLLOWUP_ISSUE=$(gh issue create \
      --title "$ISSUE_TITLE" \
      --body-file "$FOLLOWUP_BODY_FILE" \
      --label "$ISSUE_LABELS" \
      2>&1); then
      rm -f "$FOLLOWUP_BODY_FILE"
      FOLLOWUP_NUMBER=$(echo "$FOLLOWUP_ISSUE" | grep -oE '[0-9]+$' || echo "")

      # Write durable local evidence FIRST — before any network call.
      # This is the primary fallback when the PR comment write fails (see below).
      # The evidence file persists in RITE_LOCK_DIR after the lock is released,
      # so waiters that acquire the lock later can detect the prior creation even
      # when the GitHub search index and comment API both lag or fail.
      # Must be called while the lock is held (serialised write).
      if ! write_followup_evidence "$PR_NUMBER" "$FOLLOWUP_NUMBER" "${ISSUE_NUMBER:-}"; then
        print_warning "⚠️  Could not write local evidence file for follow-up #$FOLLOWUP_NUMBER (see error above) — dedup relies solely on GitHub API"
      fi

      # Post the machine-readable marker comment BEFORE releasing the lock.
      # Waiters use this comment as a secondary evidence source for index-lag
      # races.  The local evidence file (above) is the primary fallback when
      # this comment write fails.
      COMMENT_BODY="<!-- sharkrite-followup-issue:$FOLLOWUP_NUMBER -->
📋 **Consolidated follow-up issue created:** #$FOLLOWUP_NUMBER

All review feedback has been grouped into a single issue for batch processing:
- 🔴 HIGH priority: $HIGH_COUNT
- 🟡 MEDIUM priority: $MEDIUM_COUNT
- 🟢 LOW priority: $LOW_COUNT

This approach allows all fixes to be completed together in a focused PR."

      COMMENT_BODY_FILE=$(mktemp)
      printf '%s' "$COMMENT_BODY" > "$COMMENT_BODY_FILE"
      # Note: comment failure is non-fatal — local evidence (above) covers the
      # dedup gap.  We still warn so the failure is visible in logs.
      if ! gh pr comment "$PR_NUMBER" --body-file "$COMMENT_BODY_FILE" 2>/dev/null; then
        print_warning "⚠️  PR comment write failed for follow-up #$FOLLOWUP_NUMBER — local evidence file will cover dedup"
      fi
      rm -f "$COMMENT_BODY_FILE"

      # Release lock only after both evidence writes have been attempted
      [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${ISSUE_NUMBER:-}" 2>/dev/null || true
      _followup_lock_held=false

      echo ""
      print_success "✅ Follow-up issue created: #$FOLLOWUP_NUMBER"
      echo "  URL: $FOLLOWUP_ISSUE"
      echo "  Type: ${CREATE_SECURITY_DEBT:+Tech Debt}${CREATE_SECURITY_DEBT:-Review Follow-up}"
      echo "  Items: NOW=${ACTIONABLE_NOW_COUNT:-0}, LATER=${ACTIONABLE_LATER_COUNT:-0} (total in issue)"
      echo ""
    else
      rm -f "$FOLLOWUP_BODY_FILE"
      # Release lock on failure too — don't leave waiters stuck
      [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${ISSUE_NUMBER:-}" 2>/dev/null || true
      _followup_lock_held=false
      print_warning "Failed to create consolidated follow-up issue"
    fi
  fi

  # Safety net: ensure lock is released even if we exited the if/else via an
  # unexpected path (set +e is active in this section so errexit won't catch it)
  [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${ISSUE_NUMBER:-}" 2>/dev/null || true

  # Follow-up issues are independent work — don't process them inline.
  # The exec into batch-process-issues.sh caused state corruption: it would
  # run the follow-up as a full lifecycle on the same PR, then try to re-process
  # the original issue in a confused state. Follow-ups should be picked up
  # by a separate `rite <issue>` invocation.
  if [ -n "${FOLLOWUP_NUMBER:-}" ]; then
    print_info "Follow-up issue #$FOLLOWUP_NUMBER created — run \`rite $FOLLOWUP_NUMBER\` separately to address it"
  fi

  fi  # end _skip_followup_creation guard
fi
set -e  # Re-enable errexit after follow-up issue creation

# Final summary — use MERGE_EXIT_CODE (decided before follow-up creation)
print_header "✅ Assessment Complete"

echo "Summary of actions taken:"
[ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ] && [ -n "${FOLLOWUP_NUMBER:-}" ] && echo "  ✅ Follow-up issue #$FOLLOWUP_NUMBER created for HIGH/MEDIUM items"
[ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ] && [ -z "${FOLLOWUP_NUMBER:-}" ] && echo "  ⚠️  Follow-up issue creation failed (items not tracked)"
[ "${CREATE_LOW_BATCH:-false}" = true ] && [ "${LOW_COUNT:-0}" -gt 0 ] && echo "  ✅ Batched LOW priority items into single issue"

echo ""

if [ "$MERGE_EXIT_CODE" -eq 0 ]; then
  print_success "All issues resolved or tracked - ready to proceed"
  exit 0
else
  print_error "CRITICAL issues remain — manual intervention required"
  exit 1
fi
