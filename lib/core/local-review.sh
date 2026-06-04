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
# Runs a local Sharkrite review using Claude and posts findings as a PR comment.
#
# Sourceable functions (available when sourced as a library):
#   fetch_pr_diff PR_NUMBER PR_BASE PR_HEAD
#     — Fetches the PR diff with retry and local git fallback. Outputs diff to
#       stdout. Returns 0 on success, 1 on total failure.
#   validate_diff_not_empty PR_NUMBER PR_DIFF DIFF_FILES
#     — Validates that the diff is non-empty, cross-checking GitHub's changedFiles
#       count to distinguish a silent fetch failure from a legitimately empty PR.
#       Returns 0 if diff is valid, exits 1 if empty (always non-return on empty).
#
# Tests source this file with RITE_SOURCE_FUNCTIONS_ONLY=1 to load only the
# function definitions without executing the script body.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f fetch_pr_diff >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# fetch_pr_diff: fetch PR diff with retry and local git fallback
#
# Usage: fetch_pr_diff PR_NUMBER PR_BASE PR_HEAD
#   PR_NUMBER — GitHub PR number
#   PR_BASE   — base branch name (e.g. main)
#   PR_HEAD   — head branch name (e.g. fix/my-feature)
#
# Outputs the diff to stdout. Returns 0 on success, 1 if both GitHub API and
# local git diff fail.
#
# Environment:
#   RITE_DIFF_RETRY_BACKOFF — if set, overrides the exponential backoff sleep
#     duration (seconds). Set to 0 in tests to skip sleep.
#
# Dependencies: requires print_warning, print_error, print_status (from
#   lib/utils/logging.sh) to be available in the calling environment.
#   When sourcing with RITE_SOURCE_FUNCTIONS_ONLY=1 (test use), the caller
#   must provide stub implementations of these helpers before invoking this
#   function.
# ---------------------------------------------------------------------------
fetch_pr_diff() {
  local PR_NUMBER="$1"
  local PR_BASE="$2"
  local PR_HEAD="$3"

  # gh_safe handles transient 5xx/429 retries internally (3 attempts, exponential backoff)
  local PR_DIFF=""
  local GH_DIFF_ERROR=""

  set +e
  PR_DIFF=$(gh_safe pr diff "$PR_NUMBER" 2>/tmp/gh_diff_err_$$)
  local GH_DIFF_RC=$?
  GH_DIFF_ERROR=$(cat /tmp/gh_diff_err_$$ 2>/dev/null || true)
  rm -f /tmp/gh_diff_err_$$
  set -e

  # If gh_safe failed or returned empty, fall back to local git diff
  if [ $GH_DIFF_RC -ne 0 ] || [ -z "$PR_DIFF" ]; then
    print_warning "GitHub diff API unavailable — falling back to local git diff"

    # Use git diff with the three-dot syntax (merge-base..HEAD)
    # This matches what gh pr diff returns: changes in HEAD since diverging from base
    local GIT_DIFF_ERROR=""
    set +e
    PR_DIFF=$(git diff "origin/$PR_BASE...origin/$PR_HEAD" 2>/tmp/git_diff_err_$$)
    local GIT_DIFF_RC=$?
    GIT_DIFF_ERROR=$(cat /tmp/git_diff_err_$$ 2>/dev/null || true)
    rm -f /tmp/git_diff_err_$$
    set -e

    if [ $GIT_DIFF_RC -ne 0 ]; then
      print_error "Failed to fetch diff via both GitHub API and local git"
      echo ""
      echo "GitHub API error:"
      echo "$GH_DIFF_ERROR"
      echo ""
      echo "Git diff error:"
      echo "$GIT_DIFF_ERROR"
      return 1
    fi

    print_status "Using local git diff as fallback"
  fi

  echo "$PR_DIFF"
  return 0
}

# ---------------------------------------------------------------------------
# validate_diff_not_empty: check diff is non-empty; cross-check GitHub file count
#
# Usage: validate_diff_not_empty PR_NUMBER PR_DIFF DIFF_FILES
#   PR_NUMBER  — GitHub PR number (used for the changedFiles API cross-check)
#   PR_DIFF    — the raw diff string
#   DIFF_FILES — count of "diff --git" headers already computed by the caller
#
# Returns 0 if the diff is non-empty (valid for review).
# Exits 1 (does not return) if the diff is empty, after printing an appropriate
# warning: "Empty diff after fetch" when GitHub reports changed files (silent
# fetch failure), or "No code changes to review" for a legitimately empty PR.
#
# Dependencies: requires print_warning, print_info (from lib/utils/logging.sh)
#   to be available in the calling environment.
#   When sourcing with RITE_SOURCE_FUNCTIONS_ONLY=1 (test use), the caller
#   must provide stub implementations of these helpers before invoking this
#   function.
# ---------------------------------------------------------------------------
validate_diff_not_empty() {
  local PR_NUMBER="$1"
  local PR_DIFF="$2"
  local DIFF_FILES="$3"

  if [ "$DIFF_FILES" -eq 0 ] || [ -z "$PR_DIFF" ] || [ "$PR_DIFF" = "" ]; then
    # Query GitHub for the PR's known file-change count.
    # A mismatch (GitHub says N > 0 but diff is empty) indicates a silent fetch
    # failure (e.g., GitHub returned 200 OK with an empty body, or git diff ran
    # against stale refs). A match at 0 means the PR genuinely has no changes.
    local GH_CHANGED_FILES
    GH_CHANGED_FILES=$(gh_safe pr view "$PR_NUMBER" --json changedFiles --jq '.changedFiles' || true)
    GH_CHANGED_FILES="${GH_CHANGED_FILES:-0}"
    # Sanitize: strip whitespace and ensure it's numeric; default to 0 on error.
    GH_CHANGED_FILES=$(echo "$GH_CHANGED_FILES" | tr -d '[:space:]')
    if ! echo "$GH_CHANGED_FILES" | grep -qE '^[0-9]+$'; then
      GH_CHANGED_FILES=0
    fi

    if [ "$GH_CHANGED_FILES" -gt 0 ]; then
      # GitHub reports changes but we got no diff — likely a silent fetch failure.
      print_warning "Empty diff after fetch — but GitHub reports $GH_CHANGED_FILES changed file(s)"
      print_info "This indicates the diff fetch returned empty content despite real changes existing."
      print_info "Possible causes:"
      echo "  • GitHub API returned 200 OK with empty body (transient)"
      echo "  • Local git refs are stale (run: git fetch origin)"
      echo "  • Rate limit silently truncated the response"
      echo ""
      print_info "Remediation: retry this command, or run 'git fetch origin' and retry."
    else
      print_warning "No code changes to review"
      print_info "This PR has no diff against the base branch."
      print_info "Possible reasons:"
      echo "  • PR only has placeholder commit (no implementation yet)"
      echo "  • All changes were reverted"
      echo "  • Branch is identical to base"
    fi
    echo ""
    # Exit non-zero so callers know no review was generated.
    # Previously exited 0, which caused silent failures in the fix loop:
    # create-pr.sh thought the review succeeded, but nothing was posted,
    # leading to infinite stale-review reroutes in workflow-runner.sh.
    exit 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Guard: when sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, stop here so tests
# can load only the function definitions above without executing the script body
# (which sources config, parses args, calls gh/claude, etc.).
# ---------------------------------------------------------------------------
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$SCRIPT_DIR/../utils/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
source "$RITE_LIB_DIR/providers/provider-interface.sh"
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

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

# Resolve issue number: from env (workflow), or from PR body (standalone)
if [ -z "${ISSUE_NUMBER:-}" ]; then
  ISSUE_NUMBER=$(gh_safe pr view "$PR_NUMBER" --json body --jq '.body' | grep -oE "$CLOSING_ISSUE_GREP_REGEX" | head -1 | grep -oE '[0-9]+' || true)
  ISSUE_NUMBER="${ISSUE_NUMBER:-}"
fi

print_header "🦈 Sharkrite Code Review — Issue #${ISSUE_NUMBER:-$PR_NUMBER}"
echo ""

# Get PR info
print_status "Fetching PR information..."
PR_INFO=$(gh_safe pr view "$PR_NUMBER" --json title,baseRefName,headRefName,url) || {
  print_error "Failed to fetch PR #$PR_NUMBER"
  exit 1
}
PR_INFO="${PR_INFO:-}"
if [ -z "$PR_INFO" ]; then
  print_error "PR #$PR_NUMBER not found or inaccessible"
  exit 1
fi

PR_TITLE=$(echo "$PR_INFO" | jq -r '.title')
PR_BASE=$(echo "$PR_INFO" | jq -r '.baseRefName')
PR_HEAD=$(echo "$PR_INFO" | jq -r '.headRefName' || true)
PR_URL=$(echo "$PR_INFO" | jq -r '.url')

echo "  Title: $PR_TITLE"
echo "  Branch: $PR_HEAD -> $PR_BASE"
echo "  URL: $PR_URL"
echo ""

# Get the diff with fallback to local git diff
# gh_safe handles transient 5xx/429 retries internally (3 attempts, exponential backoff)
print_status "Fetching PR diff..."

PR_DIFF=$(fetch_pr_diff "$PR_NUMBER" "$PR_BASE" "$PR_HEAD") || exit 1

# printf '%s\n' ensures a trailing newline so wc -l counts the last line even
# when the diff output has no trailing newline (wc -l counts newline characters,
# so a single line with no trailing newline would return 0 without this).
DIFF_LINES=$(printf '%s\n' "$PR_DIFF" | wc -l | tr -d ' ')
DIFF_FILES=$(echo "$PR_DIFF" | grep -c "^diff --git" || true)
print_status "Diff size: $DIFF_FILES files, $DIFF_LINES lines"
echo ""

# Handle empty diff — cross-check against GitHub's file count to distinguish
# "fetch returned empty body (silent failure)" from "PR genuinely has no changes".
validate_diff_not_empty "$PR_NUMBER" "$PR_DIFF" "$DIFF_FILES"

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

    # If auth sensitivity detected and project has a security guide, inject it
    if echo "$SENSITIVITY_HINTS" | grep -q "Authentication" && \
       [ -f "$RITE_PROJECT_ROOT/docs/security/DEVELOPMENT-GUIDE.md" ]; then
      SECURITY_GUIDE=$(cat "$RITE_PROJECT_ROOT/docs/security/DEVELOPMENT-GUIDE.md")
      SENSITIVITY_SECTION="${SENSITIVITY_SECTION}

## Project Security Guide

${SECURITY_GUIDE}"
      print_status "Injected project security guide into review"
    fi
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

_timer_start "review_generation"
print_status "Running Sharkrite review (estimated: $ESTIMATE)..."
echo ""

# Run provider to generate the review (with retry on empty output)
# Provider CLI occasionally returns empty stdout with exit 0
# (transient API error). Retry once before failing.

provider_detect_cli || exit 1

MAX_REVIEW_ATTEMPTS=2
REVIEW_ATTEMPT=0
REVIEW_OUTPUT=""
CLAUDE_ERROR=""

# sharkrite-extract: provider-retry-loop-start
while [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ] && [ -z "$REVIEW_OUTPUT" ]; do
  REVIEW_ATTEMPT=$((REVIEW_ATTEMPT + 1))
  CLAUDE_STDERR=$(mktemp)

  # Capture exit code directly (no pipeline, so no PIPESTATUS needed)
  set +e
  REVIEW_OUTPUT=$(provider_run_prompt "$REVIEW_PROMPT" "$EFFECTIVE_MODEL" "$AUTO_MODE" 2>"$CLAUDE_STDERR")
  REVIEW_EXIT=$?
  set -e

  CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
  rm -f "$CLAUDE_STDERR"

  if [ "${REVIEW_EXIT:-0}" -eq 124 ]; then
    print_warning "Claude call timed out after ${RITE_CLAUDE_TIMEOUT_PROMPT:-600}s — aborting"
    exit 124
  fi

  if [ "${REVIEW_EXIT:-0}" -ne 0 ]; then
    print_error "Review failed (exit code: $REVIEW_EXIT)"
    if [ -n "$CLAUDE_ERROR" ]; then
      echo "Error output:"
      echo "$CLAUDE_ERROR"
    fi
    exit 1
  fi

  if [ -z "$REVIEW_OUTPUT" ] && [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ]; then
    print_warning "Provider returned empty review (attempt $REVIEW_ATTEMPT/$MAX_REVIEW_ATTEMPTS) — retrying in 3s..."
    sleep 3
  fi
done
# sharkrite-extract: provider-retry-loop-end

if [ -z "$REVIEW_OUTPUT" ]; then
  print_error "Provider returned empty review after $MAX_REVIEW_ATTEMPTS attempts"
  if [ -n "$CLAUDE_ERROR" ]; then
    echo "stderr output:" >&2
    echo "$CLAUDE_ERROR" >&2
  fi
  exit 1
fi

_timer_end "review_generation"
print_success "Review generated successfully"
echo ""

# Add marker with model metadata for assessment consistency
REVIEW_COMMENT="<!-- ${RITE_MARKER_REVIEW} model:${EFFECTIVE_MODEL} timestamp:$(date -u +"%Y-%m-%dT%H:%M:%SZ") -->

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

  # Diagnostic logging for health reports
  _diag "REVIEW issue=${ISSUE_NUMBER:-?} critical=${CRITICAL_COUNT:-0} high=${HIGH_COUNT:-0} medium=${MEDIUM_COUNT:-0} low=${LOW_COUNT:-0}"

  # Post as PR comment (via temp file to avoid shell interpretation of
  # backticks and $() in code blocks within the review content)
  print_status "Posting review to PR #$PR_NUMBER..."

  COMMENT_FILE=$(mktemp)
  printf '%s' "$REVIEW_COMMENT" > "$COMMENT_FILE"

  # gh_safe handles transient 5xx/429 retries internally
  set +e
  REVIEW_RESULT=$(gh_safe pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE" 2>&1)
  POST_RC=$?
  set -e
  rm -f "$COMMENT_FILE"

  if [ $POST_RC -ne 0 ]; then
    print_error "Failed to post review to PR #$PR_NUMBER"
    echo "$REVIEW_RESULT"
    echo ""
    echo "Review content (not posted):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$REVIEW_OUTPUT"
    exit 1
  fi

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
