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

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f check_assessment_freshness >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/labels.sh"
source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
# issue-lock.sh: provides derive_followup_finding_key and write_followup_evidence
# used to seed the local-evidence oracle (Source 1) for each ACTIONABLE_LATER finding.
source "$RITE_LIB_DIR/utils/issue-lock.sh"

# Source PR detection for shared commit timestamp utility
source "$RITE_LIB_DIR/utils/pr-detection.sh"

# Source provider abstraction
source "$RITE_LIB_DIR/providers/provider-interface.sh"
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

# Reuse (don't duplicate) _resolve_done_def from assess-and-resolve.sh so the
# surviving ACTIONABLE_LATER follow-up bodies use the same runbook-compliant
# done-definition wording as the per-finding loop.  Functions-only source: the
# RITE_SOURCE_FUNCTIONS_ONLY=1 guard in assess-and-resolve.sh returns before its
# program body (no arg parsing, no exec redirects, no live gh/claude calls); its
# pre-guard sources are utils + pr-detection only — no source cycle back here.
# The declare -f guard makes this a no-op if the function is already loaded.
if ! declare -f _resolve_done_def >/dev/null 2>&1; then
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/core/assess-and-resolve.sh"
fi

# =============================================================================
# FRESHNESS CHECK: Skip assessment if no commits since last assessment
# =============================================================================
# Assessments are stored as PR comments with <!-- sharkrite-assessment --> markers.
# If no commits have been pushed since the last assessment, reuse it.

check_assessment_freshness() {
  local pr_number="$1"

  # Find the most recent assessment comment timestamp
  local assessment_timestamp _jq_assessment_ts
  _jq_assessment_ts="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].createdAt"
  assessment_timestamp=$(gh_safe pr view "$pr_number" --json comments \
    --jq "$_jq_assessment_ts" || true)

  if [ -z "$assessment_timestamp" ] || [ "$assessment_timestamp" = "null" ]; then
    return 1  # No assessment exists
  fi

  # Get latest commit timestamp (local git preferred, API fallback)
  get_latest_work_commit_time "." "$pr_number"
  local latest_commit_time="$LATEST_COMMIT_TIME"

  if [ -z "$latest_commit_time" ]; then
    return 1  # Can't determine, run fresh
  fi

  # Compare timestamps (epoch comparison, portable GNU/BSD)
  local assess_epoch commit_epoch
  assess_epoch=$(iso_to_epoch "$assessment_timestamp")
  commit_epoch=$(iso_to_epoch "$latest_commit_time")

  if [ "$commit_epoch" -gt "$assess_epoch" ]; then
    return 1  # Commits after assessment = stale
  fi

  # Assessment is fresh — return the assessment content (after the --- separator)
  local assessment_body _jq_assessment_body
  _jq_assessment_body="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].body"
  assessment_body=$(gh_safe pr view "$pr_number" --json comments \
    --jq "$_jq_assessment_body" || true)

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

# =============================================================================
# PRIOR DECISIONS LEDGER: Build context of prior assessment decisions for this PR
# =============================================================================
# Fetches all previous sharkrite-assessment comments for the PR and extracts
# DISMISSED and ACTIONABLE_LATER items. Passed to the assessor so it can
# inherit prior decisions rather than re-litigating stable findings.
#
# Deduplication: processes oldest-to-newest; most recent classification wins.
# The assessor's instruction requires active justification (specific code change
# in the relevant area) to override a prior DISMISSED decision.

build_prior_decisions_ledger() {
  local pr_number="$1"

  # Fetch all sharkrite assessment comments, newest first
  # (newest-first + skip-if-seen = latest classification wins, no declare -A needed)
  local assessments_json _jq_all_assessments
  _jq_all_assessments="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse"
  assessments_json=$(gh_safe pr view "$pr_number" --json comments \
    --jq "$_jq_all_assessments" || true)
  assessments_json="${assessments_json:-[]}"

  local count
  count=$(echo "$assessments_json" | jq 'length' 2>/dev/null || echo "0")
  [ "$count" -eq 0 ] && echo "" && return 0

  local ledger=""
  local seen_titles=""  # newline-separated list of titles already recorded
  local i comment_body timestamp assessment_content changed_files
  local _cur_title _cur_state _cur_reason

  for i in $(seq 0 $((count - 1))); do
    comment_body=$(echo "$assessments_json" | jq -r ".[$i].body" 2>/dev/null || echo "")
    timestamp=$(echo "$assessments_json" | jq -r ".[$i].createdAt" 2>/dev/null || echo "")

    # Assessment content lives after the '---' separator in the comment body
    assessment_content=$(echo "$comment_body" | sed -n '/^---$/,$p' | tail -n +2 || true)
    [ -z "$assessment_content" ] && continue

    # Files changed since this assessment (informational — lets assessor judge relevance)
    changed_files=""
    if [ -n "$timestamp" ]; then
      changed_files=$(git log --name-only --pretty=format: --after="$timestamp" HEAD 2>/dev/null \
        | sort -u | grep -v '^$' | head -20 | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g' || true)
    fi

    # Parse DISMISSED and ACTIONABLE_LATER items via awk with structured prefix output
    # (avoids pipe-in-data issues with IFS splitting)
    while IFS= read -r line; do
      case "$line" in
        ITEM_TITLE:*) _cur_title="${line#ITEM_TITLE:}" ;;
        ITEM_STATE:*) _cur_state="${line#ITEM_STATE:}" ;;
        ITEM_REASON:*) _cur_reason="${line#ITEM_REASON:}" ;;
        ITEM_END)
          if [ -n "${_cur_title:-}" ]; then
            # Skip if we already recorded this title (newest-first means first-seen = latest)
            if ! printf '%s\n' "$seen_titles" | grep -qxF "$_cur_title"; then
              seen_titles="${seen_titles}
${_cur_title}"
              local entry
              entry="### ${_cur_title} - ${_cur_state}
**Reasoning:** ${_cur_reason}
**Classified:** ${timestamp}"
              if [ -n "$changed_files" ]; then
                entry="${entry}
**Files changed since:** ${changed_files}"
              fi
              ledger="${ledger}${entry}

"
            fi
          fi
          _cur_title="" _cur_state="" _cur_reason=""
          ;;
      esac
    done < <(echo "$assessment_content" | awk '
      /^### .* - DISMISSED$/ || /^### .* - ACTIONABLE_LATER$/ {
        if (title != "") {
          print "ITEM_TITLE:" title
          print "ITEM_STATE:" item_state
          print "ITEM_REASON:" reasoning
          print "ITEM_END"
        }
        line = $0; gsub(/^### /, "", line)
        item_state = line; gsub(/^.* - /, "", item_state)
        title = line; gsub(/ - [A-Z_]+$/, "", title)
        reasoning = ""
        next
      }
      /^### / {
        if (title != "") {
          print "ITEM_TITLE:" title
          print "ITEM_STATE:" item_state
          print "ITEM_REASON:" reasoning
          print "ITEM_END"
          title = ""; reasoning = ""; item_state = ""
        }
        next
      }
      title != "" && /^\*\*Reasoning:\*\*/ {
        reasoning = $0; gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
      }
      END {
        if (title != "") {
          print "ITEM_TITLE:" title
          print "ITEM_STATE:" item_state
          print "ITEM_REASON:" reasoning
          print "ITEM_END"
        }
      }
    ')
  done

  echo "$ledger"
}

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
  TOTAL_FINDINGS=$(echo "$FINDINGS_LINE" | grep -oE "[0-9]+" | awk '{sum += $1} END {print sum}' || true)
  if [ "${TOTAL_FINDINGS:-0}" -eq 0 ]; then
    print_success "Review has zero findings — nothing to assess" >&2
    echo "NO_ACTIONABLE_ITEMS"
    exit 0
  fi
fi

# Get original issue context for scope assessment
ISSUE_CONTEXT=$(gh_safe pr view "$PR_NUMBER" --json body --jq '.body' | grep -oE "$CLOSING_ISSUE_GREP_REGEX" | head -1 | grep -oE '[0-9]+' || true)
if [ -n "$ISSUE_CONTEXT" ]; then
  ISSUE_DETAILS=$(gh_safe issue view "$ISSUE_CONTEXT" --json title,body --jq '"Issue #" + (.number|tostring) + ": " + .title + "\n\n" + .body' || true)
  ISSUE_DETAILS="${ISSUE_DETAILS:-Issue context unavailable}"
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
# PRIOR DECISIONS LEDGER: Fetch prior assessment decisions for this PR
# =============================================================================
# On first run this is empty. On retry loops it contains all prior DISMISSED
# and ACTIONABLE_LATER decisions so the assessor can inherit stable decisions
# rather than re-litigating findings that already have settled classifications.

print_status "Fetching prior assessment decisions..."
PRIOR_DECISIONS_LEDGER=$(build_prior_decisions_ledger "$PR_NUMBER" 2>/dev/null || echo "")

PRIOR_DECISIONS_SECTION=""
if [ -n "$PRIOR_DECISIONS_LEDGER" ]; then
  PRIOR_ITEM_COUNT=$(echo "$PRIOR_DECISIONS_LEDGER" | grep -c "^### " || true)
  print_status "Loaded $PRIOR_ITEM_COUNT prior decision(s) into assessor context"
  PRIOR_DECISIONS_SECTION="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PRIOR ASSESSMENT DECISIONS FOR THIS PR:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

The following findings were classified in earlier assessment iterations for this PR.
Inherit these decisions unless you can identify a specific, relevant code change
that directly addresses the concern raised. \"Files changed\" alone is NOT grounds to
override a prior DISMISSED decision — you must identify a concrete change in the
specific area the finding concerns (e.g. the finding is about function X, and
function X was actually modified since the dismissal).

${PRIOR_DECISIONS_LEDGER}
"
else
  print_status "No prior assessment decisions found (first iteration)"
fi

# Error detection now handled by provider_detect_error() from provider abstraction.
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
- When genuinely uncertain between two classifications:
    * ACTIONABLE_NOW over ACTIONABLE_LATER (do not defer real, in-scope work)
    * DISMISSED over ACTIONABLE_LATER for cosmetic / stylistic / nice-to-have /
      speculative \"could improve\" findings — file a follow-up ONLY when deferring
      is genuinely necessary (see the ACTIONABLE_LATER bar below)
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

${PRIOR_DECISIONS_SECTION}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
  NECESSITY BAR: ACTIONABLE_LATER is for genuinely necessary future work ONLY: a
  real defect, a correctness or security risk, or a broken contract that MUST be
  tracked. To classify a finding ACTIONABLE_LATER you MUST state, in one phrase,
  what concretely breaks or regresses if it is never done. If you cannot, it is
  NOT ACTIONABLE_LATER. The following are DISMISSED, not deferred: cosmetic
  issues, style/naming preferences, speculative \"could improve\" / \"might be
  nice\", redundant-but-harmless code, and nice-to-have test coverage with no
  concrete regression risk.

  - Functional inconsistencies across the codebase (e.g., different validation
    rules for the same concept in different files)
  - Security-relevant findings that are out of scope but real and verifiable
  - Bugs or inconsistencies discovered incidentally that aren't blocking the PR
  - Missing tests for existing functionality (not new code in this PR)
  - Changes to UNRELATED systems or modules (different domain entirely)
  - Large refactors requiring NEW architectural patterns (>2 hours)
  - Breaking changes to PUBLIC APIs affecting external consumers
  - Work requiring NEW dependencies or significant infrastructure changes
  - Items that need design discussion or team consensus first

  KEY DISTINCTION: \"Out of scope\" is NOT the same as \"not worth tracking.\"
  A finding can be BOTH out of scope for the current PR AND worth creating
  a follow-up issue. If it's a real, verifiable problem (not opinion), it
  belongs in ACTIONABLE_LATER even if the fix is small.

  SCOPE BAR (the issue's OWN acceptance criteria are never deferrable):
  Compare every finding against the ORIGINAL ISSUE SCOPE section above. A
  finding that identifies an UNMET acceptance criterion or core deliverable
  of the issue CURRENTLY UNDER ASSESSMENT is ACTIONABLE_NOW and MUST NOT be
  deferred to ACTIONABLE_LATER — it is the work the issue exists to do.
  Only findings OUTSIDE the issue's stated scope are eligible for
  ACTIONABLE_LATER. Concretely: if a feature's own deliverable is incomplete
  — the event/token it must emit is never emitted, a subscription or wiring
  the feature requires is missing, or an artifact the issue advertises (an
  alarm, an endpoint, a config key) does not exist — that is ACTIONABLE_NOW,
  not ACTIONABLE_LATER. Deferring a feature's own core functionality ships it
  non-functional.

DISMISSED - Not worth tracking:
  - Pure style/formatting preferences (no functional impact)
  - \"Could also do X instead of Y\" where both approaches are valid
  - Over-engineering suggestions (add abstraction, make configurable, etc.)
  - Speculative edge cases with no evidence of real impact
  - Already documented as accepted patterns or intentional decisions
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
{FOR ACTIONABLE_NOW: **Location:** {specific file path and/or function name where fix should land}}
{FOR ACTIONABLE_NOW: **Fix Effort:** {<10min|<1hr|>1hr}}
{FOR ACTIONABLE_LATER: **Location:** {specific file(s), module, or domain this finding applies to — must be concrete enough that someone unfamiliar with the PR can find the right code}}
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
  - Functional inconsistency across files (e.g., validation rule X in one file,
    contradicting rule Y in another — even if small to fix)
  - Security-relevant finding that is real and verifiable but out of PR scope
  - Bug discovered incidentally (reproducible, not speculative)
  - Missing tests for existing (not new) functionality
  - Changes to UNRELATED systems (different module/domain entirely)
  - Large refactor requiring >2 hours AND new architectural patterns
  - Breaking changes to PUBLIC APIs affecting external consumers
  - Requires NEW dependencies or significant infrastructure changes
  - Needs design discussion or team consensus before implementing

  REMEMBER: A real bug that is out of scope is ACTIONABLE_LATER, not DISMISSED.
  BUT: Speculative optimizations for scale/features that don't exist yet are
  DISMISSED, not ACTIONABLE_LATER. \"Might need an index someday\" is not a
  real, verifiable problem — it's a prediction about future load.

**LOW severity + ACTIONABLE_LATER:** LOW items create issue overhead that rarely justifies the tracking cost. A LOW finding should only be ACTIONABLE_LATER if it represents a **real functional or security concern** — not code style, hypothetical improvements, or \"consider doing X\" suggestions. When in doubt, DISMISS LOW items. Examples:
  - LOW + ACTIONABLE_LATER: Missing input validation that could cause a real (not theoretical) data integrity issue
  - LOW + DISMISSED: \"Consider adding logging\", \"unnecessary type ignore comment\", \"could optimize this query\"

DISMISSED (not worth tracking) IF:
  - Pure style/formatting preference with no functional benefit
  - \"Could also do X\" where both approaches are equally valid
  - Over-engineering suggestion (premature abstraction, add configurability)
  - Speculative concern without concrete evidence or reproduction steps
  - Already documented as intentional or accepted pattern
  - LOW severity suggestion phrased as \"consider\", \"might want to\", or \"could\"
  - Duplicates an item already classified as ACTIONABLE_NOW
  - ScopeCreep items that are speculative AND require functionality, scale,
    or infrastructure that does not currently exist (e.g., indexes for queries
    that aren't written, pagination for datasets that aren't large, retention
    policies for logs that aren't accumulating)

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

_timer_start "claude_assessment"
print_status "Running Claude assessment (this may take 30-60 seconds)..."

# Run Claude assessment with retry on empty output (transient API failures).
# Provider CLI occasionally returns empty stdout with exit 0 (API blip, network issue).
# Retry up to 2 times before failing loud.
MAX_ASSESSMENT_ATTEMPTS=2
ASSESSMENT_ATTEMPT=0
ASSESSMENT_OUTPUT=""
CLAUDE_ERROR=""
CLAUDE_ERROR_TYPE=""

# Run Claude assessment - mode depends on supervised vs unsupervised
if [ "$AUTO_MODE" = true ]; then
  # UNSUPERVISED MODE: Use --print and --dangerously-skip-permissions for automation
  #
  # SECURITY NOTE: Permission bypass is used intentionally for automation.
  # Input is strictly controlled: only PR review text from GitHub API.
  # Assessment task is read-only: classify review items (no code execution).
  ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-300}"

  while [ $ASSESSMENT_ATTEMPT -lt $MAX_ASSESSMENT_ATTEMPTS ] && [ -z "$ASSESSMENT_OUTPUT" ]; do
    ASSESSMENT_ATTEMPT=$((ASSESSMENT_ATTEMPT + 1))

    # Capture stderr to debug issues while keeping stdout clean for piping
    CLAUDE_STDERR=$(mktemp)

    # Run provider assessment with timeout.
    # Use tee to display output while also capturing it.
    # Capture exit code via a temp file — PIPESTATUS doesn't survive $() subshells.
    _exit_file=$(mktemp)
    ASSESSMENT_OUTPUT=$({ provider_run_prompt_with_timeout "$ASSESSMENT_PROMPT" "$EFFECTIVE_MODEL" true "$ASSESSMENT_TIMEOUT" 2>"$CLAUDE_STDERR"; echo $? > "$_exit_file"; } | tee /dev/stderr)
    ASSESSMENT_EXIT_CODE=$(cat "$_exit_file")
    rm -f "$_exit_file"

    CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
    rm -f "$CLAUDE_STDERR"

    # Check for timeout (exit code 124) - fail immediately, don't retry
    if [ $ASSESSMENT_EXIT_CODE -eq 124 ]; then
      print_warning "Assessment timed out after ${ASSESSMENT_TIMEOUT}s"
      print_info "Try increasing timeout: export RITE_ASSESSMENT_TIMEOUT=600"
      print_info "Falling back to creating issue with all items"
      echo "ALL_ITEMS"
      exit 0
    elif [ $ASSESSMENT_EXIT_CODE -ne 0 ]; then
      # Non-zero exit: detect error type and fail immediately (don't retry)
      CLAUDE_ERROR_TYPE=$(provider_detect_error "$CLAUDE_ERROR" "$ASSESSMENT_EXIT_CODE")
      export CLAUDE_ERROR_TYPE

      print_error "Provider exited with code $ASSESSMENT_EXIT_CODE"
      echo "" >&2
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
      echo -e "${RED}DETECTED ERROR: $CLAUDE_ERROR_TYPE${NC}" >&2
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

      case "$CLAUDE_ERROR_TYPE" in
        PROVIDER_BUG)
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

      # Exit immediately on non-zero exit codes (don't fall through to retry logic)
      exit 1
    fi

    # Empty output with exit 0: retry if attempts remain
    if [ -z "$ASSESSMENT_OUTPUT" ] && [ $ASSESSMENT_ATTEMPT -lt $MAX_ASSESSMENT_ATTEMPTS ]; then
      print_warning "Provider returned empty assessment (attempt $ASSESSMENT_ATTEMPT/$MAX_ASSESSMENT_ATTEMPTS) — retrying in 3s..." >&2
      sleep 3
    fi
  done
else
  # SUPERVISED MODE: Interactive provider session with permission prompts
  print_status "Starting interactive $(provider_name) session..."
  print_status "You can review and approve assessment decisions"
  echo ""

  while [ $ASSESSMENT_ATTEMPT -lt $MAX_ASSESSMENT_ATTEMPTS ] && [ -z "$ASSESSMENT_OUTPUT" ]; do
    ASSESSMENT_ATTEMPT=$((ASSESSMENT_ATTEMPT + 1))

    # Capture stderr to debug issues while keeping stdout clean for piping
    CLAUDE_STDERR=$(mktemp)

    # Run provider assessment.
    # Use tee to display output while also capturing it.
    # Capture exit code via a temp file — PIPESTATUS doesn't survive $() subshells.
    _exit_file=$(mktemp)
    ASSESSMENT_OUTPUT=$({ provider_run_prompt "$ASSESSMENT_PROMPT" "$EFFECTIVE_MODEL" false 2>"$CLAUDE_STDERR"; echo $? > "$_exit_file"; } | tee /dev/stderr)
    ASSESSMENT_EXIT_CODE=$(cat "$_exit_file")
    rm -f "$_exit_file"

    CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
    rm -f "$CLAUDE_STDERR"

    if [ $ASSESSMENT_EXIT_CODE -ne 0 ]; then
      # Non-zero exit: detect error type and fail immediately (don't retry)
      CLAUDE_ERROR_TYPE=$(provider_detect_error "$CLAUDE_ERROR" "$ASSESSMENT_EXIT_CODE")
      export CLAUDE_ERROR_TYPE

      print_error "Provider exited with code $ASSESSMENT_EXIT_CODE"
      echo "" >&2
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
      echo -e "${RED}DETECTED ERROR: $CLAUDE_ERROR_TYPE${NC}" >&2
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

      case "$CLAUDE_ERROR_TYPE" in
        PROVIDER_BUG)
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

      # Exit immediately on non-zero exit codes (don't fall through to retry logic)
      exit 1
    fi

    # Empty output with exit 0: retry if attempts remain
    if [ -z "$ASSESSMENT_OUTPUT" ] && [ $ASSESSMENT_ATTEMPT -lt $MAX_ASSESSMENT_ATTEMPTS ]; then
      print_warning "Provider returned empty assessment (attempt $ASSESSMENT_ATTEMPT/$MAX_ASSESSMENT_ATTEMPTS) — retrying in 3s..." >&2
      sleep 3
    fi
  done
fi

# After all retry attempts: if still empty, fail loud (do NOT fall back to heuristic)
if [ -z "$ASSESSMENT_OUTPUT" ]; then
  print_error "Assessment Claude call returned empty output after $MAX_ASSESSMENT_ATTEMPTS retries"
  echo "" >&2
  echo "This indicates a transient API failure, not an actual empty assessment." >&2
  echo "Refusing to fall through to heuristic filter (which silently merges without proper assessment)." >&2
  echo "" >&2
  echo "Re-run assessment manually: rite ${RITE_ISSUE_NUMBER:-$PR_NUMBER} --assess-and-fix" >&2
  exit 1
fi

_timer_end "claude_assessment"
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
ASSESSMENT_COMMENT="<!-- ${RITE_MARKER_ASSESSMENT} pr:${PR_NUMBER} iteration:1 timestamp:${ASSESSMENT_TIMESTAMP} -->

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

# Post assessment as PR comment (via temp file to avoid shell metacharacter issues)
if [ -n "${RITE_ISSUE_NUMBER:-}" ]; then
  print_status "Posting assessment for issue #${RITE_ISSUE_NUMBER}..."
else
  print_status "Posting assessment to PR #$PR_NUMBER..."
fi
ASSESSMENT_BODY_FILE=$(mktemp)
printf '%s' "$ASSESSMENT_COMMENT" > "$ASSESSMENT_BODY_FILE"
if gh_safe pr comment "$PR_NUMBER" --body-file "$ASSESSMENT_BODY_FILE" >/dev/null 2>&1; then
  print_success "Assessment posted to PR"
else
  print_warning "Failed to post assessment comment (continuing anyway)"
fi
rm -f "$ASSESSMENT_BODY_FILE"

# =============================================================================
# CREATE/UPDATE TECH-DEBT ISSUES FOR ACTIONABLE_LATER ITEMS
# =============================================================================

if [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
  print_status "Processing $ACTIONABLE_LATER_COUNT ACTIONABLE_LATER items..."

  # Get existing open tech-debt and review-follow-up issues to check for duplicates
  EXISTING_TECH_DEBT=$(gh_safe issue list --state open --label "tech-debt" --json number,title --jq '.[] | "\(.number):\(.title)"' || true)
  EXISTING_FOLLOWUPS=$(gh_safe issue list --state open --label "review-follow-up" --json number,title --jq '.[] | "\(.number):\(.title)"' || true)
  EXISTING_ISSUES=$(printf '%s\n%s' "$EXISTING_TECH_DEBT" "$EXISTING_FOLLOWUPS" | grep -v '^$' || true)

  # Also check for issues already linked to this PR
  PR_LINKED_ISSUES=$(gh_safe pr view "$PR_NUMBER" --json body --jq '.body' | grep -oE "Follow-up.*#[0-9]+" | grep -oE "#[0-9]+" || true)

  # One-time PR metadata fetch — reused across all per-finding follow-up bodies
  # below (Claude Context + Scope Boundary DO bullets + Branch line). Mirrors
  # assess-and-resolve.sh:1627-1646. Fetched ONCE here before the while-read loop;
  # never inside it. Combined into a single gh call to halve the network cost.
  # NOTE: main-script-body scope — plain assignment only (no `local`); every
  # $()-pipeline ends `|| true` (UNSAFE_PIPE_IN_CMDSUB rule).
  _pr_meta=$(gh_safe pr view "$PR_NUMBER" --json files,headRefName 2>/dev/null || true)
  CHANGED_FILES=$(echo "$_pr_meta" | jq -r '.files[].path' 2>/dev/null || true)
  CHANGED_FILES="${CHANGED_FILES:-}"
  PR_BRANCH_NAME=$(echo "$_pr_meta" | jq -r '.headRefName' 2>/dev/null || true)
  PR_BRANCH_NAME="${PR_BRANCH_NAME:-unknown}"
  CLAUDE_CONTEXT=""
  if [ -n "$CHANGED_FILES" ]; then
    CLAUDE_CONTEXT=$(echo "$CHANGED_FILES" | sed 's/^/- `/' | sed 's/$/`/' || true)
  fi
  if [ -n "$CHANGED_FILES" ]; then
    SCOPE_DO_BULLETS=$(echo "$CHANGED_FILES" | sed 's/^/- DO: /' || true)
  else
    SCOPE_DO_BULLETS="- DO: Address the specific review finding described above"
  fi

  # Parse each ACTIONABLE_LATER item and create/update issues
  CREATED_ISSUES=""
  UPDATED_ISSUES=""
  # _item_index is the per-finding counter used to derive the followup key
  # via derive_followup_finding_key.  It does NOT mirror assess-and-resolve.sh's
  # _finding_index: the two loops iterate different populations (this loop sees
  # only ACTIONABLE_LATER; assess-and-resolve.sh sees ACTIONABLE_NOW + ACTIONABLE_LATER
  # and also has a per-finding cap that consumes _finding_index slots without
  # emitting issues).  Keys produced here will therefore diverge from those
  # produced by the assess-and-resolve path when the cap fires or when
  # ACTIONABLE_NOW items precede ACTIONABLE_LATER items in the assessment output.
  # Source 1 dedup (evidence-file lookup) is best-effort across paths; Sources
  # 2 and 3 (sentinel + title search) are the reliable dedup gates.
  # LOW-severity items do NOT increment the counter.
  _item_index=0

  # Extract ACTIONABLE_LATER sections from assessment (process substitution avoids subshell variable loss)
  while read -r line; do
    case "$line" in
      TITLE:*)
        # Normalize ITEM_TITLE using the same two-stage stripping as
        # assess-and-resolve.sh's _clean_title so both paths embed an
        # identical title in per-finding PR comments.  Without this,
        # _followup_dedup_check Source 4 (grep -cF "${_clean_title}")
        # relies on clean_title being a substring of a list-marked title
        # — a coupling that silently breaks if either normalization path
        # diverges.  The two stages mirror lines 1685-1687 of
        # assess-and-resolve.sh exactly; keep them in sync.
        _raw_item_title="${line#TITLE:}"
        # Stage 1: strip leading list markers ("1. ", "2. ", "- ", "* ")
        ITEM_TITLE=$(echo "$_raw_item_title" | sed 's/^[0-9][0-9]*\.[[:space:]]*//' | sed 's/^[-*][[:space:]]*//' || true)
        # Stage 2: trim leading/trailing whitespace
        ITEM_TITLE=$(echo "$ITEM_TITLE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
        ITEM_SEVERITY=""
        ITEM_CATEGORY=""
        ITEM_REASONING=""
        ITEM_CONTEXT=""
        ITEM_DEFER=""
        # Reset Location so a finding without one can't inherit the prior finding's.
        ITEM_LOCATION=""
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
      \*\*Location:\*\**)
        ITEM_LOCATION="${line#\*\*Location:\*\* }"
        ;;
      \*\*Defer\ Reason:\*\**)
        ITEM_DEFER="${line#\*\*Defer Reason:\*\* }"
        ;;
      ---END---)
        # Severity gate: LOW findings are logged but do not justify issue overhead.
        # They accumulate noise in the tracker and rarely get addressed.
        if echo "$ITEM_SEVERITY" | grep -qi "LOW"; then
          print_info "  Skipped (LOW severity): $ITEM_TITLE" >&2
          continue
        fi

        # Increment after LOW-severity skip (same gate as assess-and-resolve.sh).
        # Note: the index will diverge from assess-and-resolve.sh's _finding_index
        # when the cap or ACTIONABLE_NOW items are in play — see comment above.
        _item_index=$((_item_index + 1))

        # Derive the per-finding key (same algorithm as assess-and-resolve.sh's
        # _FOLLOWUP_FINDING_KEY) so evidence written here is found by
        # _followup_dedup_check Source 1 on any cross-path re-run.
        _item_finding_key=$(derive_followup_finding_key \
          "${RITE_ISSUE_NUMBER:-0}" "$ITEM_TITLE" "$_item_index")

        # Stage 1: fuzzy title match against cached issue list (both tech-debt and review-follow-up)
        DUPLICATE_ISSUE=""
        if [ -n "$EXISTING_ISSUES" ]; then
          TITLE_WORDS=$(echo "$ITEM_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
          while IFS=: read -r issue_num issue_title; do
            EXISTING_WORDS=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
            MATCH_COUNT=0
            for word in $TITLE_WORDS; do
              if [ ${#word} -gt 3 ] && echo "$EXISTING_WORDS" | grep -qw "$word"; then
                MATCH_COUNT=$((MATCH_COUNT + 1))
              fi
            done
            if [ "$MATCH_COUNT" -ge 2 ]; then
              DUPLICATE_ISSUE="$issue_num"
              break
            fi
          done <<< "$EXISTING_ISSUES"
        fi

        # Stage 2: description match via GitHub search (catches same finding re-flagged across different PRs)
        #
        # The source-issue marker is quoted ("sharkrite-source-issue:N") to force GitHub's
        # full-text search to treat it as a literal phrase rather than a structured qualifier.
        # Without quotes, GitHub may tokenize around the colon and fail to match the marker
        # embedded inside an HTML comment.
        if [ -z "$DUPLICATE_ISSUE" ] && [ -n "$ITEM_REASONING" ]; then
          REASONING_KEYWORDS=$(echo "$ITEM_REASONING" | tr '[:upper:]' '[:lower:]' | \
            tr -cs 'a-z0-9' ' ' | tr ' ' '\n' | awk 'length>4' | head -5 | tr '\n' ' ')
          if [ -n "${REASONING_KEYWORDS// /}" ]; then
            SEARCH_QUALIFIER="$REASONING_KEYWORDS in:body"
            [ -n "${RITE_ISSUE_NUMBER:-}" ] && \
              SEARCH_QUALIFIER="\"${RITE_MARKER_SOURCE_ISSUE}:${RITE_ISSUE_NUMBER}\" $REASONING_KEYWORDS in:body"
            _dup_candidate=$(gh_safe issue list \
              --state open \
              --search "$SEARCH_QUALIFIER" \
              --json number \
              --jq '.[0].number' | grep -E '^[0-9]+$' || true)
            _dup_candidate="${_dup_candidate:-}"
            # Verify the marker is actually in the body — GitHub search can return
            # approximate matches; direct body inspection is the ground truth.
            # Only applies when the source-issue marker was included in the search qualifier.
            if [ -n "$_dup_candidate" ] && [ -n "${RITE_ISSUE_NUMBER:-}" ]; then
              _dup_body=$(gh_safe issue view "$_dup_candidate" --json body --jq '.body' || true)
              _dup_body="${_dup_body:-}"
              if echo "$_dup_body" | grep -qE "${RITE_MARKER_SOURCE_ISSUE}:${RITE_ISSUE_NUMBER}([^[:alnum:]_-]|$)"; then
                DUPLICATE_ISSUE="$_dup_candidate"
              fi
            elif [ -n "$_dup_candidate" ]; then
              DUPLICATE_ISSUE="$_dup_candidate"
            fi
          fi
        fi

        if [ -n "$DUPLICATE_ISSUE" ]; then
          # Only update if the existing body is missing content we have
          EXISTING_BODY=$(gh_safe issue view "$DUPLICATE_ISSUE" --json body --jq '.body' || true)
          EXISTING_BODY="${EXISTING_BODY:-}"
          REASONING_SIGNATURE=$(echo "$ITEM_REASONING" | head -c 60 || true)
          if echo "$EXISTING_BODY" | grep -qF "$REASONING_SIGNATURE" 2>/dev/null; then
            print_info "  Already tracked in #$DUPLICATE_ISSUE (skipping): $ITEM_TITLE"
            # Passback: write issue number so assess-and-resolve.sh can skip consolidated rollup.
            if [ -n "${RITE_PER_ITEM_ISSUES_FILE:-}" ]; then
              echo "$DUPLICATE_ISSUE" >> "$RITE_PER_ITEM_ISSUES_FILE" 2>/dev/null || true
            fi
            # Source 1 (local evidence): seed the FS oracle so _followup_dedup_check
            # can short-circuit on re-runs even when the Source 4 PR comment write
            # below fails (network glitch, || true silences it).
            # No lock needed here — we are not in the create critical section; the
            # evidence file is idempotent (overwriting with same value is safe).
            write_followup_evidence "$PR_NUMBER" "$DUPLICATE_ISSUE" "${_item_finding_key:-}" \
              2>/dev/null || true
            # Post a per-finding PR comment so assess-and-resolve.sh _followup_dedup_check
            # Source 4 can detect this finding by title match on a re-run (dedup cross-path
            # guard — same rationale as the new-issue path below).
            _dup_comment_file=$(mktemp)
            printf '<!-- %s:%s -->\n**Finding:** %s' \
              "$RITE_MARKER_FOLLOWUP" "$DUPLICATE_ISSUE" "$ITEM_TITLE" \
              > "$_dup_comment_file"
            gh_safe pr comment "$PR_NUMBER" --body-file "$_dup_comment_file" \
              >/dev/null 2>&1 || true
            rm -f "$_dup_comment_file"
          else
            print_info "  Updating #$DUPLICATE_ISSUE with new content: $ITEM_TITLE"
            UPDATED_BODY="${EXISTING_BODY}

---

## Additional Assessment (PR #${PR_NUMBER})

**Severity:** ${ITEM_SEVERITY}
**Reasoning:** ${ITEM_REASONING}
**Context:** ${ITEM_CONTEXT}
**Defer Reason:** ${ITEM_DEFER}

_Added by Sharkrite on ${ASSESSMENT_TIMESTAMP}_"

            EDIT_BODY_FILE=$(mktemp)
            printf '%s' "$UPDATED_BODY" > "$EDIT_BODY_FILE"
            _issue_edit_rc=0
            gh_safe issue edit "$DUPLICATE_ISSUE" --body-file "$EDIT_BODY_FILE" >/dev/null 2>&1 \
              || _issue_edit_rc=$?
            rm -f "$EDIT_BODY_FILE"
            if [ "$_issue_edit_rc" -eq 0 ]; then
              UPDATED_ISSUES="${UPDATED_ISSUES}#${DUPLICATE_ISSUE} "
              # Passback: write issue number so assess-and-resolve.sh can skip consolidated rollup.
              # Only passback on success — a failed edit leaves the duplicate issue body unchanged,
              # so the finding must not be silently dropped from the batch outcome.
              if [ -n "${RITE_PER_ITEM_ISSUES_FILE:-}" ]; then
                echo "$DUPLICATE_ISSUE" >> "$RITE_PER_ITEM_ISSUES_FILE" 2>/dev/null || true
              fi
              # Source 1 (local evidence): seed the FS oracle (same rationale as the
              # "already tracked" and "new issue" paths above/below).
              write_followup_evidence "$PR_NUMBER" "$DUPLICATE_ISSUE" "${_item_finding_key:-}" \
                2>/dev/null || true
              # Post a per-finding PR comment so assess-and-resolve.sh _followup_dedup_check
              # Source 4 can detect this finding by title match on a re-run.
              _upd_comment_file=$(mktemp)
              printf '<!-- %s:%s -->\n**Finding:** %s' \
                "$RITE_MARKER_FOLLOWUP" "$DUPLICATE_ISSUE" "$ITEM_TITLE" \
                > "$_upd_comment_file"
              gh_safe pr comment "$PR_NUMBER" --body-file "$_upd_comment_file" \
                >/dev/null 2>&1 || true
              rm -f "$_upd_comment_file"
            else
              print_warning "Could not update duplicate issue #${DUPLICATE_ISSUE} body (gh issue edit failed with exit ${_issue_edit_rc}); finding will be re-evaluated"
            fi
          fi
        else
          # Create new issue
          print_info "  Creating issue: $ITEM_TITLE"
          SOURCE_ISSUE_MARKER=""
          [ -n "${RITE_ISSUE_NUMBER:-}" ] && SOURCE_ISSUE_MARKER="<!-- ${RITE_MARKER_SOURCE_ISSUE}:${RITE_ISSUE_NUMBER} -->"

          # Priority label fix (defect #4): derive priority from the item's severity
          # so HIGH findings are distinguishable from cosmetic items in triage.
          _priority_label="priority-medium"
          case "${ITEM_SEVERITY:-MEDIUM}" in
            CRITICAL|HIGH) _priority_label="priority-high" ;;
            MEDIUM)        _priority_label="priority-medium" ;;
            LOW)           _priority_label="priority-low" ;;
            *)             _priority_label="priority-medium" ;;
          esac

          # --- Synthesize runbook-compliant body fields (mirrors assess-and-resolve.sh:1829-1865) ---
          # The surviving ACTIONABLE_LATER follow-up uses the SAME rich body shape
          # as the per-finding loop: acceptance criterion + concrete verification
          # command derived from Location + severity-appropriate done definition.
          _acceptance_criterion="- [ ] [${ITEM_SEVERITY:-MEDIUM}] ${ITEM_TITLE}"
          if [ -n "${ITEM_LOCATION:-}" ]; then
            # Parse file:line format (e.g. "lib/core/foo.sh:142 — description text").
            # Strip any trailing description after whitespace; then split on the last colon
            # that is followed only by digits so we handle paths like lib/core/foo.sh:142
            # but not bare paths without a line number.
            _loc_path=$(echo "${ITEM_LOCATION:-}" | awk '{print $1}' | sed 's/:[0-9]*$//' || true)
            _loc_line=$(echo "${ITEM_LOCATION:-}" | awk '{print $1}' | grep -oE ':[0-9]+$' | tr -d ':' || true)
            # Sanitize _loc_path: it is LLM-derived.  A single-quote in the path would
            # break the surrounding single-quoted sed/grep command strings and inject
            # arbitrary shell text into the generated verification command.
            # Only allow the safe subset [A-Za-z0-9/._-]; anything else falls back to prose.
            _loc_path_safe=""
            if echo "${_loc_path:-}" | grep -qE '^[A-Za-z0-9/._-]+$'; then
              _loc_path_safe="$_loc_path"
            fi
            if [ -n "$_loc_line" ] && [ -n "$_loc_path_safe" ]; then
              # file:line format — emit a valid sed command pointing at that exact line
              _verification_cmd="sed -n '${_loc_line}p' '${_loc_path_safe}'"
            elif [ -n "$_loc_path_safe" ]; then
              # Looks like a plain file path (no line number) — use grep to inspect it
              _verification_cmd="grep -n '' '${_loc_path_safe}'"
            elif echo "${ITEM_LOCATION:-}" | grep -qE '^[a-zA-Z/._-]'; then
              # Location present but path did not pass sanitization — emit as prose to
              # avoid injecting unsanitized content into shell command syntax.
              _verification_cmd="# TODO: add verification command for: ${ITEM_LOCATION:-}"
            else
              # Location field present but doesn't look like a path — fall back
              _verification_cmd="# TODO: add verification command for: ${ITEM_LOCATION:-}"
            fi
          else
            # Generic fallback — reviewer must fill in the concrete command
            _verification_cmd="# TODO: add verification command for this finding"
          fi

          # Done Definition: severity-appropriate (reused function from assess-and-resolve.sh)
          _done_def=$(_resolve_done_def "${ITEM_SEVERITY:-MEDIUM}")

          # --- Build runbook-compliant issue body (mirrors assess-and-resolve.sh:1879-1922) ---
          ISSUE_BODY="${SOURCE_ISSUE_MARKER}<!-- ${RITE_MARKER_PARENT_PR}:${PR_NUMBER} -->
## Description

${ITEM_REASONING:-$ITEM_TITLE}

**Severity:** ${ITEM_SEVERITY:-MEDIUM}
**Category:** ${ITEM_CATEGORY:-unspecified}
**Source PR:** #${PR_NUMBER}
**Branch:** ${PR_BRANCH_NAME}
**Review Date:** $(date +%Y-%m-%d)
$([ -n "${ITEM_LOCATION:-}" ] && echo "**Location:** ${ITEM_LOCATION:-}" || echo "")
$([ -n "${ITEM_DEFER:-}" ] && echo "
**Defer Reason:** ${ITEM_DEFER:-}" || echo "")
$([ -n "${ITEM_CONTEXT:-}" ] && echo "
**Context:** ${ITEM_CONTEXT:-}" || echo "")

## Claude Context
Files to read before starting:
${CLAUDE_CONTEXT:-_See changed files in PR #${PR_NUMBER}_}

## Acceptance Criteria
${_acceptance_criterion}

## Verification Commands
\`\`\`bash
${_verification_cmd}
\`\`\`

## Done Definition
${_done_def}

## Scope Boundary
${SCOPE_DO_BULLETS}
- DO NOT: Refactor surrounding code, add new features, or modify unrelated files

## Dependencies
After: #${RITE_ISSUE_NUMBER:-${PR_NUMBER}}

---
_Created by Sharkrite assessment on ${ASSESSMENT_TIMESTAMP}_
_Parent PR: #${PR_NUMBER}_"

          CREATE_BODY_FILE=$(mktemp)
          printf '%s' "$ISSUE_BODY" > "$CREATE_BODY_FILE"
          ensure_labels_exist "tech-debt,from-review,${_priority_label}"
          ISSUE_URL=$(gh_safe issue create \
            --title "$ITEM_TITLE" \
            --body-file "$CREATE_BODY_FILE" \
            --label "tech-debt" \
            --label "from-review" \
            --label "$_priority_label" || true)
          ISSUE_URL="${ISSUE_URL:-}"
          rm -f "$CREATE_BODY_FILE"

          if [ -n "$ISSUE_URL" ]; then
            NEW_ISSUE=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || echo "")
            if [ -n "$NEW_ISSUE" ]; then
              CREATED_ISSUES="${CREATED_ISSUES}#${NEW_ISSUE} "
              print_success "  Created issue #$NEW_ISSUE"
              # Passback: write issue number to temp file so assess-and-resolve.sh
              # knows per-item issues were filed and can skip the consolidated rollup.
              if [ -n "${RITE_PER_ITEM_ISSUES_FILE:-}" ]; then
                echo "$NEW_ISSUE" >> "$RITE_PER_ITEM_ISSUES_FILE" 2>/dev/null || true
              fi
              # Source 1 (local evidence): seed the FS oracle so _followup_dedup_check
              # can short-circuit on re-runs even when the Source 4 PR comment write
              # below fails (network glitch, || true silences it).  This is the gap
              # identified in issue #729: PR #727 added Source 4 here but not Source 1.
              # No lock needed here — we are not racing another process for creation
              # (issue was just created by this process); the evidence file is
              # idempotent (overwriting with same value on a re-run is safe).
              write_followup_evidence "$PR_NUMBER" "$NEW_ISSUE" "${_item_finding_key:-}" \
                2>/dev/null || true
              # Post a per-finding PR comment with the marker + normalized item title
              # so that assess-and-resolve.sh's _followup_dedup_check Source 4 can
              # detect this issue by title match on a later re-run (e.g. merge-phase
              # re-entry after a network glitch on the initial summary comment).
              # ITEM_TITLE is already normalized (list markers stripped, whitespace
              # trimmed — see TITLE:* case above) to match _clean_title in
              # assess-and-resolve.sh; Source 4's grep -cF on _clean_title is therefore
              # an exact match rather than a fragile substring match (issue #728).
              # Without this comment, Source 4 falls through and the per-finding loop
              # creates a duplicate (live case: finance-glance #60 filed #69 here and
              # #71 in the per-finding loop on re-run — issues #720/721/722).
              _pfinding_comment_file=$(mktemp)
              printf '<!-- %s:%s -->\n**Finding:** %s' \
                "$RITE_MARKER_FOLLOWUP" "$NEW_ISSUE" "$ITEM_TITLE" \
                > "$_pfinding_comment_file"
              gh_safe pr comment "$PR_NUMBER" --body-file "$_pfinding_comment_file" \
                >/dev/null 2>&1 || true
              rm -f "$_pfinding_comment_file"
            fi
          else
            print_warning "  Failed to create issue: $ITEM_TITLE"
          fi
        fi
        ;;
    esac
  done < <(echo "$ASSESSMENT_OUTPUT" | awk '
    /^### / {
      # Structural block boundary: close any open ACTIONABLE_LATER block before
      # processing the new header. Block termination is deterministic (header/EOF),
      # not dependent on the LLM emitting **Defer Reason:** — so a finding that
      # omits Defer Reason is never silently dropped. (#796)
      if (in_later) { print "---END---"; in_later = 0 }
      if ($0 ~ /^### .* - ACTIONABLE_LATER$/) {
        in_later = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - ACTIONABLE_LATER$/, "", title)
        print "TITLE:" title
      }
      next
    }
    in_later && /^\*\*Severity:\*\*/ { print $0 }
    in_later && /^\*\*Category:\*\*/ { print $0 }
    in_later && /^\*\*Reasoning:\*\*/ { print $0 }
    in_later && /^\*\*Context:\*\*/ { print $0 }
    in_later && /^\*\*Location:\*\*/ { print $0 }
    in_later && /^\*\*Defer Reason:\*\*/ { print $0 }
    END { if (in_later) print "---END---" }
  ')

  # Update PR body with follow-up issue links
  if [ -n "$CREATED_ISSUES" ] || [ -n "$UPDATED_ISSUES" ]; then
    print_status "Updating PR body with follow-up issue links..."

    CURRENT_BODY=$(gh_safe pr view "$PR_NUMBER" --json body --jq '.body' || true)
    CURRENT_BODY="${CURRENT_BODY:-}"

    # Check if follow-up section already exists
    if echo "$CURRENT_BODY" | grep -q "## Follow-up Issues"; then
      # Append to existing section
      NEW_ISSUES_LINE=""
      [ -n "$CREATED_ISSUES" ] && NEW_ISSUES_LINE="Created: ${CREATED_ISSUES}"
      [ -n "$UPDATED_ISSUES" ] && NEW_ISSUES_LINE="${NEW_ISSUES_LINE} Updated: ${UPDATED_ISSUES}"

      UPDATED_BODY=$(echo "$CURRENT_BODY" | sed "/## Follow-up Issues/a\\
${NEW_ISSUES_LINE}" || true)
    else
      # Add new section
      UPDATED_BODY="${CURRENT_BODY}

---

## Follow-up Issues

**From assessment on ${ASSESSMENT_TIMESTAMP}:**
- Created: ${CREATED_ISSUES:-none}
- Updated: ${UPDATED_ISSUES:-none}"
    fi

    PR_EDIT_BODY_FILE=$(mktemp)
    printf '%s' "$UPDATED_BODY" > "$PR_EDIT_BODY_FILE"
    gh_safe pr edit "$PR_NUMBER" --body-file "$PR_EDIT_BODY_FILE" >/dev/null 2>&1 && \
      print_success "PR body updated with follow-up links" || \
      print_warning "Failed to update PR body"
    rm -f "$PR_EDIT_BODY_FILE"
  fi
fi

# ALWAYS output the full annotated assessment to stdout (includes all three states: NOW, LATER, DISMISSED)
echo "$ASSESSMENT_OUTPUT"
