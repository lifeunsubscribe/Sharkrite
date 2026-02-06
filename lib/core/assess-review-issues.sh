#!/bin/bash
# lib/core/assess-review-issues.sh
# Intelligently assess code review issues using Claude
# Determines which issues are worth fixing vs dismissing
#
# Usage:
#   assess-review-issues.sh PR_NUMBER REVIEW_FILE [--auto]
#
# Modes:
#   Supervised (default): Interactive Claude session with permissions prompts
#   Unsupervised (--auto): Non-interactive with --dangerously-skip-permissions
#
# Output: Prints assessment content to stdout (pipe-friendly, no temp files)
#   - "ALL_ITEMS" = fallback (Claude unavailable)
#   - "NO_ACTIONABLE_ITEMS" = all dismissed
#   - Assessment content = filtered ACTIONABLE items only
#
# Requires: config.sh sourced (for RITE_PROJECT_ROOT, RITE_INSTALL_DIR, etc.)

set -euo pipefail

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

PR_NUMBER="$1"
REVIEW_FILE="$2"
AUTO_MODE=false

# Check for --auto flag (unsupervised mode)
if [ "${3:-}" = "--auto" ]; then
  AUTO_MODE=true
fi

# Override print functions to send to stderr (don't interfere with stdout pipe)
print_info() { echo -e "${BLUE}ℹ️  $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✅ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}" >&2; }
print_error() { echo -e "${RED}❌ $1${NC}" >&2; }

print_info "Assessing review issues with Claude..."

# Read full review content
REVIEW_CONTENT=$(cat "$REVIEW_FILE")

# Get original issue context for scope assessment
ISSUE_CONTEXT=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null | grep -oE 'Closes #[0-9]+|Fixes #[0-9]+|Resolves #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
if [ -n "$ISSUE_CONTEXT" ]; then
  ISSUE_DETAILS=$(gh issue view "$ISSUE_CONTEXT" --json title,body --jq '"Issue #" + (.number|tostring) + ": " + .title + "\n\n" + .body' 2>/dev/null || echo "Issue context unavailable")
else
  ISSUE_DETAILS="Issue context unavailable (PR not linked to an issue)"
fi

# =============================================================================
# Load project-specific assessment context (dynamic, not hardcoded)
# =============================================================================
# Priority:
#   1. $REPO/.rite/assessment-prompt.md (project-specific override)
#   2. $REPO/CLAUDE.md (extract relevant sections dynamically)
#   3. $RITE_INSTALL_DIR/templates/assessment-prompt.md (generic fallback)

ASSESSMENT_CONTEXT=""

if [ -f "$RITE_PROJECT_ROOT/$RITE_DATA_DIR/assessment-prompt.md" ]; then
  # Project has a custom assessment prompt — use it
  ASSESSMENT_CONTEXT=$(cat "$RITE_PROJECT_ROOT/$RITE_DATA_DIR/assessment-prompt.md")
  print_info "Using project-specific assessment context (.rite/assessment-prompt.md)" >&2
elif [ -f "$RITE_PROJECT_ROOT/CLAUDE.md" ]; then
  # Extract relevant sections from project's CLAUDE.md
  # Look for security, architecture, and standards sections
  ASSESSMENT_CONTEXT=$(sed -n '/[Ss]ecurity/,/^## /p' "$RITE_PROJECT_ROOT/CLAUDE.md" 2>/dev/null | head -100 || echo "")

  # Also grab commit conventions if present
  CONVENTIONS=$(sed -n '/[Cc]ommit [Cc]onventions\|[Gg]it.*[Cc]onventions/,/^## /p' "$RITE_PROJECT_ROOT/CLAUDE.md" 2>/dev/null | head -50 || echo "")
  if [ -n "$CONVENTIONS" ]; then
    ASSESSMENT_CONTEXT="${ASSESSMENT_CONTEXT}

${CONVENTIONS}"
  fi

  if [ -n "$ASSESSMENT_CONTEXT" ]; then
    print_info "Using assessment context extracted from CLAUDE.md" >&2
  else
    # CLAUDE.md exists but no relevant sections found — use generic
    ASSESSMENT_CONTEXT=$(cat "$RITE_INSTALL_DIR/templates/assessment-prompt.md" 2>/dev/null || echo "")
    print_info "Using generic assessment context (CLAUDE.md had no relevant sections)" >&2
  fi
else
  # No project-specific context — use generic template
  ASSESSMENT_CONTEXT=$(cat "$RITE_INSTALL_DIR/templates/assessment-prompt.md" 2>/dev/null || echo "")
  print_info "Using generic assessment context (no CLAUDE.md found)" >&2
fi

# Build project context section for the prompt
PROJECT_CONTEXT_SECTION="$ASSESSMENT_CONTEXT"

# Check for project-specific security guide
if [ -f "$RITE_PROJECT_ROOT/docs/security/DEVELOPMENT-GUIDE.md" ]; then
  PROJECT_CONTEXT_SECTION="${PROJECT_CONTEXT_SECTION}
- See docs/security/DEVELOPMENT-GUIDE.md: Known security patterns, accepted risks, documented issues"
fi

# =============================================================================
# Known error detection - helps identify specific failures for fallback logic
# =============================================================================

detect_claude_error() {
  local error_output="$1"
  local exit_code="$2"

  # AJV/OAuth bug - GitHub MCP server schema validation failure
  if echo "$error_output" | grep -qiE "ajv|schema.*validation|oauth.*fail|token.*invalid|mcp.*error"; then
    echo "OAUTH_AJV_BUG"
    return 0
  fi

  # Rate limiting
  if echo "$error_output" | grep -qiE "rate.?limit|too many requests|429"; then
    echo "RATE_LIMITED"
    return 0
  fi

  # Authentication expired
  if echo "$error_output" | grep -qiE "unauthorized|401|auth.*expired|login required"; then
    echo "AUTH_EXPIRED"
    return 0
  fi

  # Network/connection issues
  if echo "$error_output" | grep -qiE "connection.*refused|network.*error|timeout|ECONNREFUSED"; then
    echo "NETWORK_ERROR"
    return 0
  fi

  # Unknown error
  echo "UNKNOWN"
  return 1
}

# Export detected error for use by workflow-runner
export CLAUDE_ERROR_TYPE=""

# Create assessment prompt for Claude
ASSESSMENT_PROMPT="You are assessing a code review.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ORIGINAL ISSUE SCOPE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$ISSUE_DETAILS

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROJECT CONTEXT:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$PROJECT_CONTEXT_SECTION

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CODE REVIEW TO ASSESS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$REVIEW_CONTENT

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ASSESSMENT TASK: Three-State Actionability
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Read the ENTIRE review holistically. Don't just pattern-match - understand context.

For EVERY finding, suggestion, or improvement mentioned:

1. READ the full context (not just keywords)
2. UNDERSTAND the intent (security? maintainability? style?)
3. ASSESS against original issue scope
4. CATEGORIZE into one of three states:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
THREE-STATE CATEGORIZATION:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ACTIONABLE_NOW - Fix in this PR cycle:
  - CRITICAL security vulnerabilities (always)
  - HIGH security issues (unless documented as accepted)
  - MEDIUM bugs that could cause production issues
  - Standards violations (breaks documented conventions)
  - Quick wins (<10 min effort, high impact)
  - Anything that blocks shipping a secure, functional product

ACTIONABLE_LATER - Valid but defer to follow-up issue:
  - Improvements that EXCEED PR scope but align with project goals
  - Valid refactoring that would take >1 hour
  - Architectural improvements (good ideas, not urgent)
  - Scope creep: \"This is good, but belongs in separate PR\"
  - Nice-to-haves under time constraints
  - Reserve for genuine improvements only (not everything!)

DISMISSED - Not worth tracking:
  - Pure style preferences (no functional impact)
  - Theoretical edge cases (unlikely in production)
  - Over-engineering (premature optimization)
  - Already documented as accepted patterns
  - Doesn't align with project goals

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
OUTPUT FORMAT:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━���━━━━

IMPORTANT: Output ONLY the assessment items in the format below. No introduction, no summary, no explanation.
Even if all items are DISMISSED, output them with reasoning so the user can see what was reviewed.

For each item, use EXACTLY this format (no deviations):

### {Brief descriptive title} - {ACTIONABLE_NOW|ACTIONABLE_LATER|DISMISSED}

**Severity:** {CRITICAL|HIGH|MEDIUM|LOW}
**Category:** {Security|CodeQuality|Standards|ScopeCreep|QuickWin}
**Reasoning:** {1-2 sentences: Why this categorization?}
**Context:** {How does this relate to original issue scope and project goals?}
{FOR ACTIONABLE_NOW: **Fix Effort:** {<10min|<1hr|>1hr}}
{FOR ACTIONABLE_LATER: **Defer Reason:** {Scope exceeds time budget|Architectural refactor needed|Needs separate focused PR}}

DO NOT add any summary section, recommendations, or extra text after the items.

CATEGORY GUIDE:
- Security: Vulnerabilities, injection risks, auth issues
- CodeQuality: Bugs, error handling, maintainability
- Standards: Convention violations
- ScopeCreep: Good idea but exceeds issue scope (can be NOW if quick win)
- QuickWin: <10min fixes with high impact (often overlaps with ScopeCreep)

---

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CRITICAL DECISION CRITERIA:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCOPE ASSESSMENT:
  - Compare review findings to original issue description
  - If finding relates to files NOT mentioned in issue -> check fix effort
  - If finding improves area BEYOND issue's stated goal -> check fix effort

  QUICK WIN SCOPE CREEP (fix immediately):
    If scope creep BUT fix takes <10 minutes -> ACTIONABLE_NOW
    Example: Issue targets file A, review suggests same change to file B
             If it's copy-paste or trivial extension -> ACTIONABLE_NOW

  DEFERRED SCOPE CREEP (track for later):
    If scope creep AND fix takes >10 minutes -> ACTIONABLE_LATER

TIME CONSTRAINTS:
  - Quick fixes (<10 min) -> ACTIONABLE_NOW (no reason to defer)
  - Medium effort (30min-1hr) -> Depends on severity
  - Large refactors (>1hr) -> ACTIONABLE_LATER unless CRITICAL

PREVENTING ISSUE PILE-UP:
  - Be selective with ACTIONABLE_LATER (not a dumping ground!)
  - Ask: 'Will we realistically fix this in next 3 months?'
  - If no -> DISMISSED (don't track things we won't do)
  - Reserve ACTIONABLE_LATER for improvements we WANT to do, just not NOW

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

IMPORTANT: Read the ENTIRE review. Don't just look for numbered lists - assess ALL findings, suggestions, and improvements mentioned anywhere in the review (including sections like 'Minor Suggestions', 'Nice to Have', 'Optional Improvements', etc.)."

print_info "Running Claude assessment (this may take 30-60 seconds)..."

# Run Claude assessment - mode depends on supervised vs unsupervised
if [ "$AUTO_MODE" = true ]; then
  # UNSUPERVISED MODE: Use --print and --dangerously-skip-permissions for automation
  #
  # SECURITY NOTE: --dangerously-skip-permissions is used intentionally for automation.
  # Input is strictly controlled: only PR review text from GitHub API.
  # Assessment task is read-only: classify review items (no code execution).
  # Falls back gracefully on failure.
  ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-120}"

  # Capture stderr to debug issues while keeping stdout clean for piping
  CLAUDE_STDERR=$(mktemp)

  # Run Claude assessment with timeout (use gtimeout on macOS if available)
  if command -v gtimeout >/dev/null 2>&1; then
    ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | gtimeout "$ASSESSMENT_TIMEOUT" claude --print --dangerously-skip-permissions 2>"$CLAUDE_STDERR")
    ASSESSMENT_EXIT_CODE=$?
  elif command -v timeout >/dev/null 2>&1; then
    ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | timeout "$ASSESSMENT_TIMEOUT" claude --print --dangerously-skip-permissions 2>"$CLAUDE_STDERR")
    ASSESSMENT_EXIT_CODE=$?
  else
    # No timeout available - run without timeout (macOS default)
    print_info "Running without timeout (install coreutils for timeout support: brew install coreutils)"
    ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | claude --print --dangerously-skip-permissions 2>"$CLAUDE_STDERR")
    ASSESSMENT_EXIT_CODE=$?
  fi

  CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
  rm -f "$CLAUDE_STDERR"

  # Check for timeout (exit code 124)
  if [ $ASSESSMENT_EXIT_CODE -eq 124 ]; then
    print_warning "Claude assessment timed out after ${ASSESSMENT_TIMEOUT}s"
    print_info "Try increasing timeout: export RITE_ASSESSMENT_TIMEOUT=300"
    print_info "Falling back to creating issue with all items"
    echo "ALL_ITEMS"
    exit 0
  elif [ $ASSESSMENT_EXIT_CODE -ne 0 ]; then
    # Detect specific error type
    CLAUDE_ERROR_TYPE=$(detect_claude_error "$CLAUDE_ERROR" "$ASSESSMENT_EXIT_CODE")
    export CLAUDE_ERROR_TYPE

    print_error "Claude CLI exited with code $ASSESSMENT_EXIT_CODE"
    echo "" >&2
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${RED}DETECTED ERROR: $CLAUDE_ERROR_TYPE${NC}" >&2
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

    case "$CLAUDE_ERROR_TYPE" in
      OAUTH_AJV_BUG)
        echo -e "${YELLOW}Known Issue: GitHub MCP OAuth/AJV schema validation bug${NC}" >&2
        echo "This is a known SDK issue affecting PR review operations." >&2
        echo "Workaround: Retry or use fallback assessment." >&2
        ;;
      RATE_LIMITED)
        echo -e "${YELLOW}Rate limited by API${NC}" >&2
        echo "Wait a few minutes before retrying." >&2
        ;;
      AUTH_EXPIRED)
        echo -e "${YELLOW}Authentication expired${NC}" >&2
        echo "Run: claude /login" >&2
        ;;
      NETWORK_ERROR)
        echo -e "${YELLOW}Network connectivity issue${NC}" >&2
        echo "Check your internet connection." >&2
        ;;
      *)
        echo -e "${YELLOW}Unknown error${NC}" >&2
        ;;
    esac

    if [ -n "$CLAUDE_ERROR" ]; then
      echo "" >&2
      echo "Full error output:" >&2
      echo "$CLAUDE_ERROR" >&2
    fi
    echo "" >&2

    ASSESSMENT_OUTPUT="ERROR: Claude assessment failed (exit code: $ASSESSMENT_EXIT_CODE, type: $CLAUDE_ERROR_TYPE)"
  fi
else
  # SUPERVISED MODE: Interactive Claude session with permission prompts
  print_info "Starting interactive Claude session..."
  print_info "You can review and approve Claude's assessment decisions"
  echo ""

  CLAUDE_STDERR=$(mktemp)
  ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | claude 2>"$CLAUDE_STDERR")
  ASSESSMENT_EXIT_CODE=$?
  CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
  rm -f "$CLAUDE_STDERR"

  if [ $ASSESSMENT_EXIT_CODE -ne 0 ]; then
    # Detect specific error type
    CLAUDE_ERROR_TYPE=$(detect_claude_error "$CLAUDE_ERROR" "$ASSESSMENT_EXIT_CODE")
    export CLAUDE_ERROR_TYPE

    print_error "Claude CLI exited with code $ASSESSMENT_EXIT_CODE"
    echo "" >&2
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${RED}DETECTED ERROR: $CLAUDE_ERROR_TYPE${NC}" >&2
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

    case "$CLAUDE_ERROR_TYPE" in
      OAUTH_AJV_BUG)
        echo -e "${YELLOW}Known Issue: GitHub MCP OAuth/AJV schema validation bug${NC}" >&2
        echo "This is a known SDK issue affecting PR review operations." >&2
        echo "Workaround: Retry or use fallback assessment." >&2
        ;;
      RATE_LIMITED)
        echo -e "${YELLOW}Rate limited by API${NC}" >&2
        echo "Wait a few minutes before retrying." >&2
        ;;
      AUTH_EXPIRED)
        echo -e "${YELLOW}Authentication expired${NC}" >&2
        echo "Run: claude /login" >&2
        ;;
      NETWORK_ERROR)
        echo -e "${YELLOW}Network connectivity issue${NC}" >&2
        echo "Check your internet connection." >&2
        ;;
      *)
        echo -e "${YELLOW}Unknown error${NC}" >&2
        ;;
    esac

    if [ -n "$CLAUDE_ERROR" ]; then
      echo "" >&2
      echo "Full error output:" >&2
      echo "$CLAUDE_ERROR" >&2
    fi
    echo "" >&2

    ASSESSMENT_OUTPUT="ERROR: Claude assessment failed (exit code: $ASSESSMENT_EXIT_CODE, type: $CLAUDE_ERROR_TYPE)"
  fi
fi

if [[ "$ASSESSMENT_OUTPUT" == "ERROR:"* ]] || [ -z "$ASSESSMENT_OUTPUT" ]; then
  if [ -n "$CLAUDE_ERROR_TYPE" ] && [ "$CLAUDE_ERROR_TYPE" != "UNKNOWN" ]; then
    print_warning "Claude assessment failed ($CLAUDE_ERROR_TYPE), falling back to heuristic filter" >&2
  else
    print_warning "Claude assessment unavailable, falling back to heuristic filter" >&2
  fi
  print_info "Using middle-ground fallback: CRITICAL + HIGH only (excluding MEDIUM/LOW)" >&2

  # Heuristic fallback: Only CRITICAL and HIGH issues
  HEURISTIC_FILTERED=$(echo "$REVIEW_CONTENT" | grep -E "^(CRITICAL|HIGH):" || echo "")

  if [ -z "$HEURISTIC_FILTERED" ]; then
    print_info "No CRITICAL or HIGH issues found in heuristic filter" >&2
    echo "NO_ACTIONABLE_ITEMS"
  else
    print_info "Heuristic filter found $(echo "$HEURISTIC_FILTERED" | wc -l | tr -d ' ') CRITICAL/HIGH items" >&2
    echo "$HEURISTIC_FILTERED"
  fi
  exit 0
fi

print_success "Assessment complete"

# Parse assessment to check for actionable items (NOW or LATER)
ACTIONABLE_NOW_ITEMS=$(echo "$ASSESSMENT_OUTPUT" | grep "ACTIONABLE_NOW" || echo "")
ACTIONABLE_LATER_ITEMS=$(echo "$ASSESSMENT_OUTPUT" | grep "ACTIONABLE_LATER" || echo "")

# Count each type for reporting
ACTIONABLE_NOW_COUNT=$(echo "$ACTIONABLE_NOW_ITEMS" | grep -c "ACTIONABLE_NOW" 2>/dev/null || echo "0")
ACTIONABLE_LATER_COUNT=$(echo "$ACTIONABLE_LATER_ITEMS" | grep -c "ACTIONABLE_LATER" 2>/dev/null || echo "0")

if [ -z "$ACTIONABLE_NOW_ITEMS" ] && [ -z "$ACTIONABLE_LATER_ITEMS" ]; then
  print_info "No actionable items found (all dismissed or clean review)"
else
  print_info "Found: $ACTIONABLE_NOW_COUNT items for immediate action, $ACTIONABLE_LATER_COUNT for later"
fi

# ALWAYS output the full annotated assessment to stdout (includes all three states: NOW, LATER, DISMISSED)
echo "$ASSESSMENT_OUTPUT"
