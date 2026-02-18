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
# FRESHNESS CHECK: Skip assessment if no commits since last assessment
# =============================================================================
# Assessments are stored as PR comments with <!-- sharkrite-assessment --> markers.
# If no commits have been pushed since the last assessment, reuse it.

check_assessment_freshness() {
  local pr_number="$1"

  # Find the most recent assessment comment timestamp
  local assessment_timestamp
  assessment_timestamp=$(gh pr view "$pr_number" --json comments \
    --jq '[.comments[] | select(.body | contains("<!-- sharkrite-assessment"))] | sort_by(.createdAt) | reverse | .[0].createdAt' 2>/dev/null || echo "")

  if [ -z "$assessment_timestamp" ] || [ "$assessment_timestamp" = "null" ]; then
    return 1  # No assessment exists
  fi

  # Get latest commit timestamp on the PR
  local latest_commit_time
  latest_commit_time=$(gh pr view "$pr_number" --json commits \
    --jq '.commits[-1].committedDate' 2>/dev/null || echo "")

  if [ -z "$latest_commit_time" ]; then
    return 1  # Can't determine, run fresh
  fi

  # Compare timestamps (epoch comparison, portable GNU/BSD)
  local assess_epoch commit_epoch
  if date --version >/dev/null 2>&1; then
    assess_epoch=$(date -d "$assessment_timestamp" "+%s" 2>/dev/null || echo "0")
    commit_epoch=$(date -d "$latest_commit_time" "+%s" 2>/dev/null || echo "0")
  else
    assess_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$assessment_timestamp" "+%s" 2>/dev/null || echo "0")
    commit_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$latest_commit_time" "+%s" 2>/dev/null || echo "0")
  fi

  if [ "$commit_epoch" -gt "$assess_epoch" ]; then
    return 1  # Commits after assessment = stale
  fi

  # Assessment is fresh — return the assessment content (after the --- separator)
  local assessment_body
  assessment_body=$(gh pr view "$pr_number" --json comments \
    --jq '[.comments[] | select(.body | contains("<!-- sharkrite-assessment"))] | sort_by(.createdAt) | reverse | .[0].body' 2>/dev/null || echo "")

  echo "$assessment_body" | sed -n '/^---$/,$p' | tail -n +2
  return 0
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
print_status() { echo -e "${BLUE}$1${NC}" >&2; }
print_success() { echo -e "${GREEN}✅ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}" >&2; }
print_error() { echo -e "${RED}❌ $1${NC}" >&2; }

print_status "Assessing review issues with Claude..."

# Read full review content
REVIEW_CONTENT=$(cat "$REVIEW_FILE")

# =============================================================================
# EARLY EXIT: Skip assessment entirely if review has zero findings
# =============================================================================
# The assessment's job is to categorize REVIEW findings into NOW/LATER/DISMISSED.
# When the review itself reports zero findings, there's nothing to categorize.
# Without this check, the assessment Claude reads positive prose and invents issues.

FINDINGS_LINE=$(echo "$REVIEW_CONTENT" | grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+ [|] LOW: [0-9]+" | head -1 || true)
if [ -n "$FINDINGS_LINE" ]; then
  TOTAL_FINDINGS=$(echo "$FINDINGS_LINE" | grep -oE "[0-9]+" | awk '{sum += $1} END {print sum}')
  if [ "${TOTAL_FINDINGS:-0}" -eq 0 ]; then
    print_success "Review has zero findings — nothing to assess" >&2
    echo "NO_ACTIONABLE_ITEMS"
    exit 0
  fi
fi

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
  print_status "Using project-specific assessment context (.rite/assessment-prompt.md)"
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
    print_status "Using assessment context extracted from CLAUDE.md"
  else
    # CLAUDE.md exists but no relevant sections found — use generic
    ASSESSMENT_CONTEXT=$(cat "$RITE_INSTALL_DIR/templates/assessment-prompt.md" 2>/dev/null || echo "")
    print_status "Using generic assessment context (CLAUDE.md had no relevant sections)"
  fi
else
  # No project-specific context — use generic template
  ASSESSMENT_CONTEXT=$(cat "$RITE_INSTALL_DIR/templates/assessment-prompt.md" 2>/dev/null || echo "")
  print_status "Using generic assessment context (no CLAUDE.md found)"
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

ACTIONABLE_NOW - Fix in this PR cycle:
  - CRITICAL security vulnerabilities (always, no exceptions)
  - HIGH bugs that would break the feature being implemented
  - Issues that make the PR UNMERGEABLE (build fails, tests fail)
  - Any valid concern WITHIN the original issue scope
  - Quick fixes (<30min) that a reasonable engineer would include
  - Logical completions of the work (e.g., if fixing regex, also fix related validation)
  - Changes in the SAME file/module that are directly related

ACTIONABLE_LATER - Valid concern, create follow-up issue:
  - Changes to UNRELATED systems or modules (different domain entirely)
  - Large refactors requiring NEW architectural patterns (>2 hours)
  - Breaking changes to PUBLIC APIs affecting external consumers
  - Work requiring NEW dependencies or significant infrastructure changes
  - Items that need design discussion or team consensus first

DISMISSED - Not worth tracking:
  - Pure style preferences (no functional impact)
  - Suggestions using words like \"consider\", \"might\", \"could\"
  - Theoretical edge cases (unlikely in production)
  - Over-engineering (premature optimization)
  - Already documented as accepted patterns
  - \"Nice to have\" without clear, immediate benefit
  - LOW priority items that don't affect functionality
  - Items already covered by ACTIONABLE_NOW (avoid duplicates)

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
DECISION CRITERIA:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ACTIONABLE_NOW (fix now) IF:
  - Security vulnerability (CRITICAL always, HIGH if exploitable)
  - Bug that breaks the feature being implemented
  - Valid concern WITHIN the original issue scope
  - Quick fix (<30min) that a reasonable engineer would include
  - Build or test failure
  - Logical completion of the work being done (same domain)
  - Changes in the SAME module that are directly related

ACTIONABLE_LATER (defer to tech-debt) IF:
  - Changes to UNRELATED systems (different module/domain entirely)
  - Large refactor requiring >2 hours AND new architectural patterns
  - Breaking changes to PUBLIC APIs affecting external consumers
  - Requires NEW dependencies or significant infrastructure changes
  - Needs design discussion or team consensus before implementing

DISMISSED (not worth tracking) IF:
  - Pure style preference with no functional benefit
  - Reviewer says \"consider\" or \"might want to\"
  - Theoretical concern without concrete evidence
  - Already documented as intentional
  - LOW priority with no clear benefit
  - Unrelated to files being modified
  - Duplicates an item already classified as ACTIONABLE_NOW

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

IMPORTANT: Read the ENTIRE review. Don't just look for numbered lists - assess ALL findings, suggestions, and improvements mentioned anywhere in the review (including sections like 'Minor Suggestions', 'Nice to Have', 'Optional Improvements', etc.)."

# Determine effective model (from review metadata or config)
EFFECTIVE_MODEL="${RITE_ASSESSMENT_MODEL:-$RITE_REVIEW_MODEL}"

# =============================================================================
# FRESHNESS CHECK: Reuse existing assessment if no commits since last one
# =============================================================================

if FRESH_ASSESSMENT=$(check_assessment_freshness "$PR_NUMBER" 2>/dev/null); then
  print_success "Using existing assessment (no new commits since last assessment)"
  echo "$FRESH_ASSESSMENT"
  exit 0
fi

print_status "Running Claude assessment (this may take 30-60 seconds)..."

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
  print_status "Starting interactive Claude session..."
  print_status "You can review and approve Claude's assessment decisions"
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

# Parse assessment to check for actionable items (NOW or LATER)
# IMPORTANT: Match structured headers only (^### Title - STATE) to avoid
# counting mentions of state names in reasoning text
ACTIONABLE_NOW_COUNT=$(echo "$ASSESSMENT_OUTPUT" | grep -c "^### .* - ACTIONABLE_NOW" || true)
ACTIONABLE_LATER_COUNT=$(echo "$ASSESSMENT_OUTPUT" | grep -c "^### .* - ACTIONABLE_LATER" || true)
DISMISSED_COUNT=$(echo "$ASSESSMENT_OUTPUT" | grep -c "^### .* - DISMISSED" || true)

if [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -eq 0 ]; then
  print_info "No actionable items found (all dismissed or clean review)"
else
  print_info "Found: $ACTIONABLE_NOW_COUNT NOW, $ACTIONABLE_LATER_COUNT LATER, $DISMISSED_COUNT DISMISSED"
fi

# =============================================================================
# POST ASSESSMENT AS PR COMMENT (source of truth for freshness + determinism)
# =============================================================================

# Build assessment summary for PR comment
ASSESSMENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ASSESSMENT_COMMENT="<!-- sharkrite-assessment pr:${PR_NUMBER} iteration:1 timestamp:${ASSESSMENT_TIMESTAMP} -->

## 🔍 Sharkrite Assessment

**PR:** #${PR_NUMBER}
**Assessed:** ${ASSESSMENT_TIMESTAMP}
**Model:** ${EFFECTIVE_MODEL}

### Summary
- **ACTIONABLE_NOW:** ${ACTIONABLE_NOW_COUNT} items (fix in this PR)
- **ACTIONABLE_LATER:** ${ACTIONABLE_LATER_COUNT} items (tech-debt)
- **DISMISSED:** ${DISMISSED_COUNT} items (not actionable)

---

${ASSESSMENT_OUTPUT}"

# Post assessment as PR comment
print_status "Posting assessment to PR #$PR_NUMBER..."
if gh pr comment "$PR_NUMBER" --body "$ASSESSMENT_COMMENT" >/dev/null 2>&1; then
  print_success "Assessment posted to PR"
else
  print_warning "Failed to post assessment comment (continuing anyway)"
fi

# =============================================================================
# CREATE/UPDATE TECH-DEBT ISSUES FOR ACTIONABLE_LATER ITEMS
# =============================================================================

if [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
  print_status "Processing $ACTIONABLE_LATER_COUNT ACTIONABLE_LATER items..."

  # Get existing open tech-debt issues to check for duplicates
  EXISTING_ISSUES=$(gh issue list --state open --label "tech-debt" --json number,title --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || echo "")

  # Also check for issues already linked to this PR
  PR_LINKED_ISSUES=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null | grep -oE "Follow-up.*#[0-9]+" | grep -oE "#[0-9]+" || echo "")

  # Parse each ACTIONABLE_LATER item and create/update issues
  CREATED_ISSUES=""
  UPDATED_ISSUES=""

  # Extract ACTIONABLE_LATER sections from assessment
  echo "$ASSESSMENT_OUTPUT" | awk '
    /^### .* - ACTIONABLE_LATER$/ {
      in_later = 1
      title = $0
      gsub(/^### /, "", title)
      gsub(/ - ACTIONABLE_LATER$/, "", title)
      print "TITLE:" title
    }
    in_later && /^\*\*Severity:\*\*/ { print $0 }
    in_later && /^\*\*Category:\*\*/ { print $0 }
    in_later && /^\*\*Reasoning:\*\*/ { print $0 }
    in_later && /^\*\*Context:\*\*/ { print $0 }
    in_later && /^\*\*Defer Reason:\*\*/ { print $0; print "---END---"; in_later = 0 }
    in_later && /^### / && !/ACTIONABLE_LATER/ { print "---END---"; in_later = 0 }
  ' | while read -r line; do
    case "$line" in
      TITLE:*)
        ITEM_TITLE="${line#TITLE:}"
        ITEM_SEVERITY=""
        ITEM_CATEGORY=""
        ITEM_REASONING=""
        ITEM_CONTEXT=""
        ITEM_DEFER=""
        ;;
      \*\*Severity:\*\**)
        ITEM_SEVERITY="${line#\*\*Severity:\*\* }"
        ;;
      \*\*Category:\*\**)
        ITEM_CATEGORY="${line#\*\*Category:\*\* }"
        ;;
      \*\*Reasoning:\*\**)
        ITEM_REASONING="${line#\*\*Reasoning:\*\* }"
        ;;
      \*\*Context:\*\**)
        ITEM_CONTEXT="${line#\*\*Context:\*\* }"
        ;;
      \*\*Defer\ Reason:\*\**)
        ITEM_DEFER="${line#\*\*Defer Reason:\*\* }"
        ;;
      ---END---)
        # Check for duplicate by fuzzy matching title
        DUPLICATE_ISSUE=""
        if [ -n "$EXISTING_ISSUES" ]; then
          # Simple fuzzy match: check if any existing issue title contains key words from this title
          TITLE_WORDS=$(echo "$ITEM_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
          while IFS=: read -r issue_num issue_title; do
            EXISTING_WORDS=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
            # Count matching words
            MATCH_COUNT=0
            for word in $TITLE_WORDS; do
              if [ ${#word} -gt 3 ] && echo "$EXISTING_WORDS" | grep -qw "$word"; then
                MATCH_COUNT=$((MATCH_COUNT + 1))
              fi
            done
            # If more than 2 significant words match, consider it a duplicate
            if [ "$MATCH_COUNT" -ge 2 ]; then
              DUPLICATE_ISSUE="$issue_num"
              break
            fi
          done <<< "$EXISTING_ISSUES"
        fi

        if [ -n "$DUPLICATE_ISSUE" ]; then
          # Update existing issue with new context
          print_info "  Updating existing issue #$DUPLICATE_ISSUE: $ITEM_TITLE"
          UPDATE_COMMENT="## Additional Context from PR #${PR_NUMBER}

**Severity:** ${ITEM_SEVERITY}
**Reasoning:** ${ITEM_REASONING}
**Context:** ${ITEM_CONTEXT}
**Defer Reason:** ${ITEM_DEFER}

_Added by Sharkrite assessment on ${ASSESSMENT_TIMESTAMP}_"

          gh issue comment "$DUPLICATE_ISSUE" --body "$UPDATE_COMMENT" >/dev/null 2>&1 && \
            UPDATED_ISSUES="${UPDATED_ISSUES}#${DUPLICATE_ISSUE} "
        else
          # Create new issue
          print_info "  Creating issue: $ITEM_TITLE"
          ISSUE_BODY="## From PR #${PR_NUMBER} Assessment

**Severity:** ${ITEM_SEVERITY}
**Category:** ${ITEM_CATEGORY}

## Issue
${ITEM_REASONING}

## Context
${ITEM_CONTEXT}

## Defer Reason
${ITEM_DEFER}

---
_Created by Sharkrite assessment on ${ASSESSMENT_TIMESTAMP}_
_Parent PR: #${PR_NUMBER}_"

          ISSUE_URL=$(gh issue create \
            --title "$ITEM_TITLE" \
            --body "$ISSUE_BODY" \
            --label "tech-debt" \
            --label "from-review" 2>/dev/null || echo "")

          if [ -n "$ISSUE_URL" ]; then
            NEW_ISSUE=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || echo "")
            if [ -n "$NEW_ISSUE" ]; then
              CREATED_ISSUES="${CREATED_ISSUES}#${NEW_ISSUE} "
              print_success "  Created issue #$NEW_ISSUE"
            fi
          else
            print_warning "  Failed to create issue: $ITEM_TITLE"
          fi
        fi
        ;;
    esac
  done

  # Update PR body with follow-up issue links
  # NOTE: CREATED_ISSUES/UPDATED_ISSUES are set inside a pipe subshell above,
  # so their values are lost here. This block won't trigger until the awk|while
  # pipeline is refactored to avoid the subshell (e.g., process substitution).
  # For now, issue creation still works — the PR body just doesn't get updated.
  if [ -n "$CREATED_ISSUES" ] || [ -n "$UPDATED_ISSUES" ]; then
    print_status "Updating PR body with follow-up issue links..."

    CURRENT_BODY=$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null)

    # Check if follow-up section already exists
    if echo "$CURRENT_BODY" | grep -q "## Follow-up Issues"; then
      # Append to existing section
      NEW_ISSUES_LINE=""
      [ -n "$CREATED_ISSUES" ] && NEW_ISSUES_LINE="Created: ${CREATED_ISSUES}"
      [ -n "$UPDATED_ISSUES" ] && NEW_ISSUES_LINE="${NEW_ISSUES_LINE} Updated: ${UPDATED_ISSUES}"

      UPDATED_BODY=$(echo "$CURRENT_BODY" | sed "/## Follow-up Issues/a\\
${NEW_ISSUES_LINE}")
    else
      # Add new section
      UPDATED_BODY="${CURRENT_BODY}

---

## Follow-up Issues

**From assessment on ${ASSESSMENT_TIMESTAMP}:**
- Created: ${CREATED_ISSUES:-none}
- Updated: ${UPDATED_ISSUES:-none}"
    fi

    gh pr edit "$PR_NUMBER" --body "$UPDATED_BODY" >/dev/null 2>&1 && \
      print_success "PR body updated with follow-up links" || \
      print_warning "Failed to update PR body"
  fi
fi

# ALWAYS output the full annotated assessment to stdout (includes all three states: NOW, LATER, DISMISSED)
echo "$ASSESSMENT_OUTPUT"
