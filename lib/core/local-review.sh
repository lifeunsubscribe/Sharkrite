#!/usr/bin/env bash
# lib/core/local-review.sh
# Run a local Sharkrite review and post it as a PR comment
#
# Usage:
#   local-review.sh <PR_NUMBER> [--post] [--auto]
#
# Options:
#   --post    Post the review as a PR comment (default: preview only)
#   --auto    Use --dangerously-skip-permissions for automation
#
# This replaces Claude for GitHub's auto-review with a local Sharkrite session.
# Benefits:
#   - No dependency on external service
#   - Faster (no webhook latency)
#   - Works when Claude for GitHub is down/broken
#   - Same review quality (same Claude model)

set -euo pipefail

# Source config if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$SCRIPT_DIR/../utils/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"

# Parse arguments
PR_NUMBER="${1:-}"
POST_REVIEW=false
AUTO_MODE=false

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --post)
      POST_REVIEW=true
      ;;
    --auto)
      AUTO_MODE=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [ -z "$PR_NUMBER" ]; then
  echo "Usage: $0 <PR_NUMBER> [--post] [--auto]"
  echo ""
  echo "Options:"
  echo "  --post    Post the review as a PR comment (default: preview only)"
  echo "  --auto    Use non-interactive mode for automation"
  echo ""
  echo "Examples:"
  echo "  $0 59           # Preview review for PR #59"
  echo "  $0 59 --post    # Generate and post review to PR #59"
  exit 1
fi

# Validate PR number
if [[ ! $PR_NUMBER =~ ^[0-9]+$ ]]; then
  print_error "Invalid PR number: must be numeric"
  exit 1
fi

print_header "🦈 Sharkrite Code Review - PR #$PR_NUMBER"
echo ""

# Display review method (set by create-pr.sh or review-helper.sh)
if [ -n "${RITE_REVIEW_REASON:-}" ]; then
  print_info "Review method: Local Sharkrite"
  print_status "   Reason: $RITE_REVIEW_REASON"
fi

# Get PR info
print_status "Fetching PR information..."
PR_INFO=$(gh pr view "$PR_NUMBER" --json title,baseRefName,headRefName,url 2>&1) || {
  print_error "Failed to fetch PR #$PR_NUMBER"
  echo "$PR_INFO"
  exit 1
}

PR_TITLE=$(echo "$PR_INFO" | jq -r '.title')
PR_BASE=$(echo "$PR_INFO" | jq -r '.baseRefName')
PR_HEAD=$(echo "$PR_INFO" | jq -r '.headRefName')
PR_URL=$(echo "$PR_INFO" | jq -r '.url')

echo "  Title: $PR_TITLE"
echo "  Branch: $PR_HEAD -> $PR_BASE"
echo "  URL: $PR_URL"
echo ""

# Get the diff
print_status "Fetching PR diff..."
PR_DIFF=$(gh pr diff "$PR_NUMBER" 2>&1) || {
  print_error "Failed to fetch diff for PR #$PR_NUMBER"
  echo "$PR_DIFF"
  exit 1
}

DIFF_LINES=$(echo "$PR_DIFF" | wc -l | tr -d ' ')
DIFF_FILES=$(echo "$PR_DIFF" | grep -c "^diff --git" || true)
print_status "Diff size: $DIFF_FILES files, $DIFF_LINES lines"
echo ""

# Handle empty diff
if [ "$DIFF_FILES" -eq 0 ] || [ -z "$PR_DIFF" ] || [ "$PR_DIFF" = "" ]; then
  print_warning "No code changes to review"
  print_info "This PR has no diff against the base branch."
  print_info "Possible reasons:"
  echo "  • PR only has placeholder commit (no implementation yet)"
  echo "  • All changes were reverted"
  echo "  • Branch is identical to base"
  echo ""
  exit 0
fi

# Load review instructions template
# Priority: 1. Repo-specific (.github/claude-code/), 2. Sharkrite default, 3. Embedded fallback
# Use absolute path from RITE_PROJECT_ROOT to avoid CWD dependency
REPO_TEMPLATE="$RITE_PROJECT_ROOT/.github/claude-code/pr-review-instructions.md"
RITE_TEMPLATE="$RITE_INSTALL_DIR/templates/github/claude-code/pr-review-instructions.md"

if [ -f "$REPO_TEMPLATE" ]; then
  REVIEW_TEMPLATE="$REPO_TEMPLATE"
  TEMPLATE_LINES=$(wc -l < "$REPO_TEMPLATE" | tr -d ' ')
  print_status "Using repo-specific review instructions ($TEMPLATE_LINES lines)"
elif [ -f "$RITE_TEMPLATE" ]; then
  REVIEW_TEMPLATE="$RITE_TEMPLATE"
  print_status "Using Sharkrite default review instructions"
else
  REVIEW_TEMPLATE=""
  print_warning "No review template found"
  print_status "Using embedded review instructions"
fi

if [ -z "$REVIEW_TEMPLATE" ]; then
  REVIEW_INSTRUCTIONS="You are a senior engineer conducting a thorough code review.
Analyze all changed files for:
1. Security vulnerabilities (highest priority)
2. Bug detection
3. Code quality
4. Performance issues
5. Test coverage

Classify findings as CRITICAL, HIGH, MEDIUM, or LOW.
Output your review in markdown format with clear sections."
else
  REVIEW_INSTRUCTIONS=$(cat "$REVIEW_TEMPLATE")
fi

# Load project context if available
PROJECT_CONTEXT=""
if [ -f "$RITE_PROJECT_ROOT/CLAUDE.md" ]; then
  PROJECT_CONTEXT="

## Project Context (from CLAUDE.md)

$(head -200 "$RITE_PROJECT_ROOT/CLAUDE.md")"
  print_status "Loaded project context from CLAUDE.md"
fi

# NOTE: No iteration context is injected here. The review must always be a fresh,
# unbiased analysis of the current code state. The assessment step
# (assess-review-issues.sh) handles comparing findings against issue scope and
# filtering previously-addressed items. If fixed items no longer appear in the
# diff, the review simply won't flag them — which is the correct behavior.

# Detect sensitivity areas from changed file patterns for enhanced review focus
SENSITIVITY_SECTION=""
if [ -n "$PR_NUMBER" ]; then
  SENSITIVITY_HINTS=$(detect_sensitivity_areas "$PR_NUMBER")
  if [ -n "$SENSITIVITY_HINTS" ]; then
    SENSITIVITY_SECTION="

## Review Sensitivity Areas

The following areas were detected in the changed files and warrant extra scrutiny. These are focus areas, not blockers. Apply heightened rigor to these specific aspects.

${SENSITIVITY_HINTS}"
    print_status "Sensitivity areas detected — review will apply extra focus"
  fi
fi

# Get current timestamp for review metadata
REVIEW_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Use consistent model for reviews (matches assessment model for determinism)
EFFECTIVE_MODEL="$RITE_REVIEW_MODEL"

# Build the full prompt
REVIEW_PROMPT="$REVIEW_INSTRUCTIONS
$PROJECT_CONTEXT
${SENSITIVITY_SECTION:-}

---

## Review Metadata

Use these values in your JSON output:
- **Model:** $EFFECTIVE_MODEL
- **Timestamp:** $REVIEW_TIMESTAMP
- **Files Analyzed:** $DIFF_FILES

---

## PR Information

**Title:** $PR_TITLE
**Branch:** $PR_HEAD -> $PR_BASE
**PR Number:** #$PR_NUMBER

---

## Code Changes (Diff)

\`\`\`diff
$PR_DIFF
\`\`\`

---

Please provide your code review following the output format specified above. Start with the human-readable markdown review, then end with the hidden JSON data block."

# Estimate review time based on diff size
if [ "$DIFF_LINES" -lt 100 ]; then
  ESTIMATE="30-60 seconds"
elif [ "$DIFF_LINES" -lt 500 ]; then
  ESTIMATE="1-2 minutes"
else
  ESTIMATE="2-4 minutes"
fi

print_status "Running Sharkrite review (estimated: $ESTIMATE)..."
echo ""

# Run Claude to generate the review (with retry on empty output)
# Claude CLI --print occasionally returns empty stdout with exit 0
# (transient API error). Retry once before failing.

# Build Claude args with model flag
CLAUDE_ARGS="--print"
if [ -n "$EFFECTIVE_MODEL" ]; then
  CLAUDE_ARGS="$CLAUDE_ARGS --model $EFFECTIVE_MODEL"
fi

MAX_REVIEW_ATTEMPTS=2
REVIEW_ATTEMPT=0
REVIEW_OUTPUT=""
CLAUDE_ERROR=""

while [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ] && [ -z "$REVIEW_OUTPUT" ]; do
  REVIEW_ATTEMPT=$((REVIEW_ATTEMPT + 1))
  CLAUDE_STDERR=$(mktemp)

  if [ "$AUTO_MODE" = true ]; then
    REVIEW_OUTPUT=$(echo "$REVIEW_PROMPT" | claude $CLAUDE_ARGS --dangerously-skip-permissions 2>"$CLAUDE_STDERR")
    REVIEW_EXIT=$?
  else
    REVIEW_OUTPUT=$(echo "$REVIEW_PROMPT" | claude $CLAUDE_ARGS 2>"$CLAUDE_STDERR")
    REVIEW_EXIT=$?
  fi

  CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
  rm -f "$CLAUDE_STDERR"

  if [ $REVIEW_EXIT -ne 0 ]; then
    print_error "Claude review failed (exit code: $REVIEW_EXIT)"
    if [ -n "$CLAUDE_ERROR" ]; then
      echo "Error output:"
      echo "$CLAUDE_ERROR"
    fi
    exit 1
  fi

  if [ -z "$REVIEW_OUTPUT" ] && [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ]; then
    print_warning "Claude returned empty review (attempt $REVIEW_ATTEMPT/$MAX_REVIEW_ATTEMPTS) — retrying in 3s..."
    sleep 3
  fi
done

if [ -z "$REVIEW_OUTPUT" ]; then
  print_error "Claude returned empty review after $MAX_REVIEW_ATTEMPTS attempts"
  if [ -n "$CLAUDE_ERROR" ]; then
    echo "stderr output:" >&2
    echo "$CLAUDE_ERROR" >&2
  fi
  exit 1
fi

print_success "Review generated successfully"
echo ""

# Add marker with model metadata for assessment consistency
REVIEW_COMMENT="<!-- sharkrite-local-review model:${EFFECTIVE_MODEL} timestamp:$(date -u +"%Y-%m-%dT%H:%M:%SZ") -->

$REVIEW_OUTPUT"

if [ "$POST_REVIEW" = true ]; then
  # Parse review for summary display
  # Prefer the structured Findings line (e.g. "Findings: [CRITICAL: 0 | HIGH: 1 | ...]")
  # to avoid matching severity keywords in metadata/reasoning text
  FINDINGS_LINE=$(echo "$REVIEW_OUTPUT" | grep -oE "CRITICAL: [0-9]+ \| HIGH: [0-9]+ \| MEDIUM: [0-9]+ \| LOW: [0-9]+" | head -1 || true)
  if [ -n "$FINDINGS_LINE" ]; then
    CRITICAL_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "CRITICAL: [0-9]+" | grep -oE "[0-9]+" || echo "0")
    HIGH_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "HIGH: [0-9]+" | grep -oE "[0-9]+" || echo "0")
    MEDIUM_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "MEDIUM: [0-9]+" | grep -oE "[0-9]+" || echo "0")
    LOW_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "LOW: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  else
    # Fallback: count section headers (less reliable)
    CRITICAL_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*critical|❌.*critical" || true)
    HIGH_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*high|⚡.*high priority" || true)
    MEDIUM_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*medium|📋.*medium priority" || true)
    LOW_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*low|💡.*low|minor suggestion" || true)
  fi

  # Post as PR comment (same location as Claude for GitHub app reviews,
  # enabling seamless switching between local and app review methods)
  print_status "Posting review to PR #$PR_NUMBER..."

  REVIEW_RESULT=$(gh pr comment "$PR_NUMBER" --body "$REVIEW_COMMENT" 2>&1) || {
    print_error "Failed to post review"
    echo "$REVIEW_RESULT"
    echo ""
    echo "Review content (not posted):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$REVIEW_OUTPUT"
    exit 1
  }

  echo ""
  print_success "Review posted successfully!"
  echo ""

  # Output summary
  echo "Review Summary:"
  echo "  CRITICAL: $CRITICAL_COUNT"
  echo "  HIGH: $HIGH_COUNT"
  echo "  MEDIUM: $MEDIUM_COUNT"
  echo "  LOW: $LOW_COUNT"

  # Extract overall assessment if present
  OVERALL_ASSESSMENT=$(echo "$REVIEW_OUTPUT" | grep -oE "Overall Assessment:.*$" | head -1 || echo "")
  if [ -n "$OVERALL_ASSESSMENT" ]; then
    echo ""
    echo "  $OVERALL_ASSESSMENT"
  fi
else
  # Preview mode - just display the review
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "REVIEW PREVIEW (not posted)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "$REVIEW_OUTPUT"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  print_info "To post this review, run:"
  echo "  $0 $PR_NUMBER --post"
fi
