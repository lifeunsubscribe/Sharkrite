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

# =============================================================================
# CACHING: SHA256 hash of review content for deterministic cache key
# =============================================================================

generate_cache_key() {
  local review_content="$1"
  local model="${2:-${RITE_REVIEW_MODEL:-opus}}"
  local cache_input="${review_content}::model=${model}"

  if command -v shasum >/dev/null 2>&1; then
    echo "$cache_input" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "$cache_input" | sha256sum | cut -d' ' -f1
  else
    echo "$cache_input" | md5 | cut -d' ' -f1
  fi
}

get_cached_assessment() {
  local cache_key="$1"
  local cache_file="$RITE_PROJECT_ROOT/$RITE_ASSESSMENT_CACHE_DIR/${cache_key}.json"

  if [ -f "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi
  return 1
}

save_to_cache() {
  local cache_key="$1"
  local assessment="$2"
  local model="${3:-${RITE_REVIEW_MODEL:-opus}}"
  local cache_dir="$RITE_PROJECT_ROOT/$RITE_ASSESSMENT_CACHE_DIR"

  mkdir -p "$cache_dir"
  echo "$assessment" > "$cache_dir/${cache_key}.json"

  # Store metadata for targeted cleanup
  cat > "$cache_dir/${cache_key}.meta" << EOF
{
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "model": "$model",
  "pr_number": "$PR_NUMBER"
}
EOF
  print_info "Cached assessment for PR #$PR_NUMBER (key: ${cache_key:0:12}...)" >&2
}

# =============================================================================
# JSON SCHEMA: Structured output schema for deterministic parsing (internal)
# =============================================================================
# NOTE: This schema is defined for future use with Claude CLI's --output-format json
# Currently unused because existing parsing expects markdown format.
# TODO: Migrate to JSON output once downstream parsing is updated.

ASSESSMENT_JSON_SCHEMA='{
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "title": {"type": "string"},
          "state": {"enum": ["ACTIONABLE_NOW", "ACTIONABLE_LATER", "DISMISSED"]},
          "severity": {"enum": ["CRITICAL", "HIGH", "MEDIUM", "LOW"]},
          "category": {"enum": ["Security", "CodeQuality", "Standards", "ScopeCreep", "QuickWin"]},
          "reasoning": {"type": "string"},
          "context": {"type": "string"},
          "fix_effort": {"type": "string"},
          "defer_reason": {"type": "string"}
        },
        "required": ["title", "state", "severity", "category", "reasoning"]
      }
    }
  },
  "required": ["items"]
}'

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
DETERMINISM REQUIREMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You MUST be consistent in your classifications.
Given identical input, you MUST produce identical output.

Rules:
- Do NOT use probabilistic language (\"might\", \"could\", \"possibly\")
- Make DEFINITIVE decisions for each item
- When genuinely uncertain between two classifications, ALWAYS choose
  the more conservative option:
    * ACTIONABLE_NOW over ACTIONABLE_LATER
    * ACTIONABLE_LATER over DISMISSED
- Apply the same reasoning pattern to similar issues
- Do NOT introduce randomness in your decision-making

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

ACTIONABLE_NOW - Fix in this PR cycle (BE CONSERVATIVE):
  - CRITICAL security vulnerabilities (always, no exceptions)
  - HIGH bugs that would BREAK the specific feature being implemented
  - Issues that make the PR UNMERGEABLE (build fails, tests fail)
  - NOTHING ELSE unless explicitly in the original issue scope

ACTIONABLE_LATER - Valid concern, create follow-up issue:
  - HIGH issues that don't block this specific feature
  - MEDIUM bugs and quality issues
  - Refactors and improvements (even good ones!)
  - Test coverage gaps in code NOT directly related to the issue
  - \"While we're here\" fixes
  - Standards violations that don't break functionality

DISMISSED - Not worth tracking:
  - Pure style preferences (no functional impact)
  - Suggestions using words like \"consider\", \"might\", \"could\"
  - Theoretical edge cases (unlikely in production)
  - Over-engineering (premature optimization)
  - Already documented as accepted patterns
  - Improvements to unrelated code
  - \"Nice to have\" without clear, immediate benefit
  - LOW priority items (almost always dismissed)
  - Anything not in the original issue scope AND not a security issue

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

CONSERVATIVE SCOPE ASSESSMENT (prefer deferral over expansion):
  - The ORIGINAL ISSUE SCOPE above defines what this PR is for
  - ONLY mark ACTIONABLE_NOW if the issue is:
    * A CRITICAL security vulnerability (always fix)
    * A HIGH bug that would break the specific feature being changed
    * Directly blocking the original issue from being complete
  - Everything else should be ACTIONABLE_LATER or DISMISSED
  - \"Scope creep\" includes:
    * Improvements to code not in the original issue
    * Refactors that weren't requested
    * Style/quality issues that don't affect functionality
    * \"While we're here\" fixes

STRICT SCOPE BOUNDARY:
  - If it wasn't in the original issue description → DISMISSED or ACTIONABLE_LATER
  - If it's a \"nice to have\" or \"improvement\" → ACTIONABLE_LATER at best
  - If the reviewer says \"consider\" or \"might want to\" → DISMISSED
  - Only CRITICAL security issues can expand scope beyond original issue
  - A reasonable engineer would include it if they noticed it

DEFER ONLY IF:
  - Large refactor requiring architectural changes (>1 hour)
  - Touches completely unrelated code/systems
  - Requires design discussion or new dependencies
  - Would need its own test suite or documentation update

DISMISS IF:
  - Pure style preference with no functional benefit
  - Unrelated to files being modified
  - Hypothetical concern without evidence
  - Already documented as intentional

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

IMPORTANT: Read the ENTIRE review. Don't just look for numbered lists - assess ALL findings, suggestions, and improvements mentioned anywhere in the review (including sections like 'Minor Suggestions', 'Nice to Have', 'Optional Improvements', etc.)."

# =============================================================================
# CACHE CHECK: Return cached result if available
# =============================================================================

# Determine effective model (from review metadata or config)
EFFECTIVE_MODEL="${RITE_ASSESSMENT_MODEL:-${RITE_REVIEW_MODEL:-opus}}"

# Generate cache key and check for cached result
CACHE_KEY=$(generate_cache_key "$REVIEW_CONTENT" "$EFFECTIVE_MODEL")

if CACHED_RESULT=$(get_cached_assessment "$CACHE_KEY" 2>/dev/null); then
  print_success "Using cached assessment (key: ${CACHE_KEY:0:12}...)"
  echo "$CACHED_RESULT"
  exit 0
fi

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

  # Build Claude args with model flag for consistency
  CLAUDE_ARGS="--print --dangerously-skip-permissions"
  if [ -n "$EFFECTIVE_MODEL" ]; then
    CLAUDE_ARGS="$CLAUDE_ARGS --model $EFFECTIVE_MODEL"
  fi

  # Run Claude assessment with timeout (use gtimeout on macOS if available)
  # Use tee to display output while also capturing it
  if command -v gtimeout >/dev/null 2>&1; then
    ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | gtimeout "$ASSESSMENT_TIMEOUT" claude $CLAUDE_ARGS 2>"$CLAUDE_STDERR" | tee /dev/stderr)
    ASSESSMENT_EXIT_CODE=${PIPESTATUS[1]}
  elif command -v timeout >/dev/null 2>&1; then
    ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | timeout "$ASSESSMENT_TIMEOUT" claude $CLAUDE_ARGS 2>"$CLAUDE_STDERR" | tee /dev/stderr)
    ASSESSMENT_EXIT_CODE=${PIPESTATUS[1]}
  else
    # No timeout available - run without timeout (macOS default)
    print_info "Running without timeout (install coreutils for timeout support: brew install coreutils)"
    ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | claude $CLAUDE_ARGS 2>"$CLAUDE_STDERR" | tee /dev/stderr)
    ASSESSMENT_EXIT_CODE=${PIPESTATUS[0]}
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

  # Build Claude args with model flag for consistency
  # Note: Using --print because stdin piping breaks interactive TTY
  CLAUDE_ARGS_SUPERVISED="--print"
  if [ -n "$EFFECTIVE_MODEL" ]; then
    CLAUDE_ARGS_SUPERVISED="$CLAUDE_ARGS_SUPERVISED --model $EFFECTIVE_MODEL"
  fi

  CLAUDE_STDERR=$(mktemp)
  ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | claude $CLAUDE_ARGS_SUPERVISED 2>"$CLAUDE_STDERR" | tee /dev/stderr)
  ASSESSMENT_EXIT_CODE=${PIPESTATUS[0]}
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

# Cache successful result for future determinism
save_to_cache "$CACHE_KEY" "$ASSESSMENT_OUTPUT" "$EFFECTIVE_MODEL"

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
