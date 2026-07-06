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

# Shared triage classifier (triage_classify_diff). Sourced via a BASH_SOURCE-
# derived path so it loads in every mode (RITE_SOURCE_FUNCTIONS_ONLY, sourced by
# the orchestrator, and standalone-script) — RITE_LIB_DIR is not yet guaranteed
# set this early. Defined here (before the FUNCTIONS_ONLY guard) so the shadow
# test can load it. Also used by the trivial-fix fast-path (#531).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../utils/triage-classify.sh"

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
# _triage_emit_shadow — SHADOW-mode triage classifier + paired logging
#
# Runs ONLY when RITE_REVIEW_TRIAGE=shadow. Classifies the diff (deterministic
# Layer-1 guards, then a cheap triage-model classifier on the cleared
# remainder) and emits ONE [diag] TRIAGE_SHADOW line pairing the haiku verdict
# with the REAL opus review's findings (passed in). NOTHING is skipped here —
# this is pure measurement for the calibration window. The weekly health report
# parses these lines to compute false-skip / false-escalate rates by category
# and by pass-type, then recommends thresholds + first-pass policy.
#
# Bias: deterministic guards (Layer 1) catch every dangerous category and force
# "substantive" regardless of the classifier; the classifier (Layer 2) only
# decides the already-safe remainder, and low confidence escalates. So even a
# wrong classifier can only ever cause a (cheap) false-escalate in the data,
# never a (dangerous) false-skip on a guarded category.
#
# Args: PR_NUMBER PR_DIFF DIFF_FILES OPUS_CRIT OPUS_HIGH OPUS_MED OPUS_LOW
# ---------------------------------------------------------------------------
_triage_emit_shadow() {
  local _pr="$1" _diff="$2" _files="$3"
  local _ocrit="${4:-0}" _ohigh="${5:-0}" _omed="${6:-0}" _olow="${7:-0}"
  local _pass="first" _prior=0
  local _cls _verdict _conf _guard _reason _size _category

  # --- pass-type: prior review marker present on the PR → fix-review iteration ---
  # Self-determined (no caller threading). Defensive: gh failure → assume first.
  _prior=$(gh_safe pr view "$_pr" --json comments \
    --jq "[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | length" 2>/dev/null || echo 0)
  # A review for THIS run may already be posted by the time we measure, so a
  # true first pass can show count 1. Treat >=2 as a genuine prior pass.
  if [ "${_prior:-0}" -ge 2 ] 2>/dev/null; then _pass="fixreview"; fi

  # Classification (Layer 1 guards + Layer 2 haiku) is shared with the fast-path.
  _cls=$(triage_classify_diff "$_pr" "$_diff" "$_files")
  IFS='|' read -r _verdict _conf _guard _reason _size _category <<<"$_cls"

  _diag "TRIAGE_SHADOW pr=${_pr} pass=${_pass} haiku=${_verdict} conf=${_conf} guard=${_guard:-none} opus_critical=${_ocrit} opus_high=${_ohigh} opus_med=${_omed} opus_low=${_olow} size_lines=${_size} files=${_files} category=${_category} reason=${_reason}"
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
source "$RITE_LIB_DIR/utils/review-helper.sh"
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

if [ -n "${ISSUE_NUMBER:-}" ]; then
  print_header "🦈 Sharkrite Code Review — Issue #${ISSUE_NUMBER}"
else
  print_header "🦈 Sharkrite Code Review — PR #${PR_NUMBER}"
fi
echo ""

# Get PR info
print_status "Fetching PR information..."
PR_INFO=$(gh_safe pr view "$PR_NUMBER" --json title,baseRefName,headRefName,url,headRefOid) || {
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    print_error "Failed to fetch PR for issue #$ISSUE_NUMBER"
  else
    print_error "Failed to fetch PR #$PR_NUMBER"
  fi
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
# HEAD SHA at review time — embedded in the review marker so assess-and-resolve.sh
# can use SHA comparison instead of timestamp comparison for staleness detection.
PR_HEAD_SHA=$(echo "$PR_INFO" | jq -r '.headRefOid // ""' 2>/dev/null || true)
PR_HEAD_SHA="${PR_HEAD_SHA:-}"

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

# sharkrite-extract: template-tier1-start
if [ -f "$REPO_TEMPLATE" ]; then
  REVIEW_TEMPLATE="$REPO_TEMPLATE"
  TEMPLATE_LINES=$(wc -l < "$REPO_TEMPLATE" | tr -d ' ')
  print_status "Using repo-specific review instructions ($TEMPLATE_LINES lines)"
  # Warn if the file exists locally but is not tracked by git — it will be
  # absent on fresh checkouts and in CI, where rite silently falls back to
  # the generic default instead of the repo-specific instructions.
  if ! git -C "$RITE_PROJECT_ROOT" ls-files --error-unmatch \
      ".github/claude-code/pr-review-instructions.md" >/dev/null 2>&1; then
    print_warning "Using repo-specific review instructions, but the file is untracked — commit it so the same review runs on fresh checkouts / in CI"
  fi
elif [ -f "$RITE_TEMPLATE" ]; then
  REVIEW_TEMPLATE="$RITE_TEMPLATE"
  print_status "Using Sharkrite default review instructions"
else
  REVIEW_TEMPLATE=""
  print_warning "No review template found"
  print_status "Using embedded review instructions"
fi
# sharkrite-extract: template-tier1-end

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

# =============================================================================
# FIXREVIEW PASS DETECTION: inject prior review + fix-commit diff for convergence
# =============================================================================
# On the first review pass the prompt is a fresh audit of the full PR diff.
# On a fixreview pass (≥1 existing review marker on this PR; checked pre-post — see note below), the prompt
# becomes a VERIFICATION pass: the prior review body and the diff of only the
# fix commits are injected so the reviewer can confirm each prior NOW finding
# is fixed or not fixed, without re-discovering pre-existing issues.
#
# This prevents the live divergence pattern (#804, 2026-07-05) where:
#   round-1: NOW=3 (fixed faithfully)
#   round-2: NOW=5 DIFFERENT items (pre-existing, missed in round 1)
# A verification-framed prompt re-anchors the reviewer to the prior set.

FIXREVIEW_CONTEXT_SECTION=""

# Count existing review markers to determine pass type.
# This check happens BEFORE the current review is generated and posted, so the
# count reflects only previously posted reviews. Any count ≥1 means a prior
# review exists and this is a fixreview pass.
#
# Note: _triage_emit_shadow uses ≥2 because it runs AFTER the review is posted
# (so the current-run review may already be counted). Here we run before posting,
# so the threshold is ≥1. Both produce equivalent detection of "prior review exists".
_prior_review_count=$(gh_safe pr view "$PR_NUMBER" --json comments \
  --jq "[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | length" \
  2>/dev/null || echo 0)
_prior_review_count="${_prior_review_count:-0}"

if [ "${_prior_review_count:-0}" -ge 1 ] 2>/dev/null; then
  print_status "Fix-review pass detected ($((${_prior_review_count:-0})) prior review(s)) — building verification context..."

  # Fetch the most recent prior review body (the one BEFORE this run).
  # We want the latest posted review; newest-first → index 0.
  _prior_review_body=$(gh_safe pr view "$PR_NUMBER" --json comments \
    --jq "[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].body" \
    2>/dev/null || true)
  _prior_review_body="${_prior_review_body:-}"

  # Extract the SHA from the prior review marker (for fix-commit diff).
  # Marker format: <!-- sharkrite-local-review ... commit:<sha> -->
  # Uses extract_review_sha (review-helper.sh) which anchors to the marker prefix
  # so a "commit:<hex>" reference inside the review prose is not mistakenly captured.
  _prior_review_sha=""
  if [ -n "$_prior_review_body" ]; then
    _prior_review_sha=$(extract_review_sha "$_prior_review_body" || true)
    _prior_review_sha="${_prior_review_sha:-}"
  fi

  # Build fix-commit diff: commits pushed after the prior review SHA.
  # Falls back to the full PR diff if the SHA is unavailable (no regression —
  # first-pass framing is always safe).
  _fix_commit_diff=""
  if [ -n "$_prior_review_sha" ] && git -C "$RITE_PROJECT_ROOT" rev-parse --verify "$_prior_review_sha" >/dev/null 2>&1; then
    _fix_commit_diff=$(git -C "$RITE_PROJECT_ROOT" diff "${_prior_review_sha}...origin/${PR_HEAD}" 2>/dev/null || true)
    _fix_commit_diff="${_fix_commit_diff:-}"
    if [ -n "$_fix_commit_diff" ]; then
      _fix_diff_lines=$(printf '%s\n' "$_fix_commit_diff" | wc -l | tr -d ' ')
      print_status "Fix-commit diff: ${_fix_diff_lines} lines since ${_prior_review_sha:0:8}"
    else
      print_status "No fix-commit diff found since ${_prior_review_sha:0:8} — verification will use full diff"
    fi
  else
    if [ -n "$_prior_review_sha" ]; then
      print_warning "Prior review SHA ${_prior_review_sha:0:8} not found locally — falling back to full diff for verification"
    else
      print_warning "Prior review has no embedded SHA — falling back to full diff for verification"
    fi
  fi

  # Build the fixreview context section injected into the prompt.
  # Only emit if we have a prior review body to anchor against.
  if [ -n "$_prior_review_body" ]; then
    _fix_diff_section=""
    if [ -n "$_fix_commit_diff" ]; then
      _fix_diff_section="
---

## Fix Commits (Changes Since Prior Review)

The following diff represents ONLY the commits pushed as fixes since the prior review.
Use this to assess whether each prior ACTIONABLE_NOW finding has been addressed:

\`\`\`diff
${_fix_commit_diff}
\`\`\`"
    fi

    FIXREVIEW_CONTEXT_SECTION="

---

## ⚠️ VERIFICATION PASS — Fix-Loop Iteration

This is a fix-loop re-review. A prior review raised ACTIONABLE_NOW findings.
The developer has applied fixes. Your job is NOT a fresh audit — it is verification.

**Instructions:**
1. For each ACTIONABLE_NOW finding in the PRIOR REVIEW below: determine FIXED or NOT FIXED based on the fix-commit diff.
   - FIXED: the concern is fully resolved → do NOT re-raise it.
   - NOT FIXED (or partially fixed): re-raise it as ACTIONABLE_NOW with a note that it was not addressed.
2. New findings are only valid if:
   - They were **introduced by the fix commits** (i.e. visible in the fix-commit diff, NOT pre-existing in the full PR diff before the fix), OR
   - They are CRITICAL severity (always surface regardless of origin).
   Do NOT re-raise pre-existing issues that were NOT flagged in the prior review.
3. Apply the same output format as a normal review.

## Prior Review (Most Recent)

${_prior_review_body}
${_fix_diff_section}"

    print_status "Fixreview context built — review will verify prior findings"
  else
    print_warning "Could not fetch prior review body — proceeding as fresh review"
  fi
fi

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
${FIXREVIEW_CONTEXT_SECTION:-}

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

## Code Changes (Full PR Diff)

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

MAX_REVIEW_ATTEMPTS=3
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

  # Timeout: the full per-call timeout already elapsed, so retrying would just
  # double the wall-clock for no benefit. Abort.
  if [ "${REVIEW_EXIT:-0}" -eq 124 ]; then
    print_warning "Claude review timed out after ${RITE_CLAUDE_TIMEOUT_PROMPT:-600}s — aborting"
    exit 124
  fi

  # Hard error (non-zero, non-timeout): a transient API/network/rate-limit blip
  # fast-fails here in seconds (live: PR reviews exit-1'd in ~14s, aborting an
  # otherwise-complete run — issues #482, #649, #631). These are retryable: a
  # momentary 429/5xx clears in seconds — but a capacity incident (HTTP 529 /
  # overloaded_error) lasts minutes-to-hours and gets its own long backoff
  # schedule below. Back off and retry rather than throw away the dev work;
  # only give up after exhausting attempts.
  if [ "${REVIEW_EXIT:-0}" -ne 0 ]; then
    # Surface the TAIL of provider stderr in every failure message. Live
    # failure (issue #823): the log recorded only "exit 1" for all three
    # attempts and the 529 root cause had to be inferred from a different
    # issue's explicit error 14 minutes later.
    _review_err_tail=$(echo "$CLAUDE_ERROR" | tail -n 5 || true)

    # Overloaded signature: HTTP 529 or the API's overloaded_error type.
    # 529 is anchored as a standalone number so unrelated text like
    # "1529 tokens" cannot match (format-anchor convention).
    _review_overloaded=false
    if echo "$CLAUDE_ERROR" | grep -qiE '(^|[^0-9])529([^0-9]|$)|overloaded_error'; then
      _review_overloaded=true
    fi

    if [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ]; then
      if [ "$_review_overloaded" = true ]; then
        # A 529 incident outlasts the default 3s/6s schedule: issue #823
        # burned all 3 retries in 9s inside a 20+ minute incident and lost
        # an otherwise-complete run (PR #830 was already pushed). Long
        # schedule (60s then 120s) so a retry can land after recovery.
        _review_backoff=$(( ${RITE_REVIEW_OVERLOADED_BACKOFF:-60} * REVIEW_ATTEMPT ))
        print_warning "Review provider overloaded (529/overloaded_error, attempt $REVIEW_ATTEMPT/$MAX_REVIEW_ATTEMPTS)${_review_err_tail:+ — stderr tail: $_review_err_tail}"
        print_warning "Using long overloaded backoff schedule — retrying in ${_review_backoff}s..."
      else
        _review_backoff=$(( ${RITE_REVIEW_RETRY_BACKOFF:-3} * REVIEW_ATTEMPT ))
        print_warning "Review provider failed (exit $REVIEW_EXIT, attempt $REVIEW_ATTEMPT/$MAX_REVIEW_ATTEMPTS)${_review_err_tail:+: $_review_err_tail} — retrying in ${_review_backoff}s..."
      fi
      REVIEW_OUTPUT=""
      sleep "$_review_backoff"
      continue
    fi
    if [ "$_review_overloaded" = true ]; then
      print_error "Review failed after $MAX_REVIEW_ATTEMPTS attempts: provider was overloaded (529/overloaded_error) — the API is under a capacity incident. Dev work and the PR are intact; re-run this issue later, once the incident clears."
    else
      print_error "Review failed (exit code: $REVIEW_EXIT) after $MAX_REVIEW_ATTEMPTS attempts"
    fi
    if [ -n "$_review_err_tail" ]; then
      print_error "Provider stderr (tail): $_review_err_tail"
    fi
    exit 1
  fi

  # Empty output (exit 0 but no review text): also a transient provider hiccup.
  if [ -z "$REVIEW_OUTPUT" ] && [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ]; then
    _review_backoff=$(( ${RITE_REVIEW_RETRY_BACKOFF:-3} * REVIEW_ATTEMPT ))
    print_warning "Provider returned empty review (attempt $REVIEW_ATTEMPT/$MAX_REVIEW_ATTEMPTS) — retrying in ${_review_backoff}s..."
    sleep "$_review_backoff"
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

# Add marker with model metadata for assessment consistency.
# The commit: attribute records the HEAD SHA at review generation time.
# assess-and-resolve.sh uses this for SHA-based staleness detection —
# a deterministic "does this review cover the current HEAD?" check that
# avoids the timestamp race conditions that caused false stale-review-loop
# failures (see issue #354, behavioral-design.md § "Stale Review Loop").
_REVIEW_SHA_ATTR=""
if [ -n "${PR_HEAD_SHA:-}" ]; then
  _REVIEW_SHA_ATTR=" commit:${PR_HEAD_SHA}"
fi
REVIEW_COMMENT="<!-- ${RITE_MARKER_REVIEW} model:${EFFECTIVE_MODEL} timestamp:$(date -u +"%Y-%m-%dT%H:%M:%SZ")${_REVIEW_SHA_ATTR} -->

$REVIEW_OUTPUT"

if [ "$POST_REVIEW" = true ]; then
  # Parse review for summary display.
  # Priority 1: the embedded sharkrite-review-data JSON — authoritative, and the
  # exact source assess-and-resolve.sh and the merge gate already parse.
  # Priority 2: the human Findings line, each severity parsed INDEPENDENTLY.
  #
  # The old joined regex required "CRITICAL: N | HIGH: N | ..." with fields
  # ADJACENT, but the real line carries emoji between them:
  #   "Findings: 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 3 | 🟢 LOW: 3"
  # so it never matched → execution fell to the header-count fallback, which
  # counts arbitrary keyword/header lines and emitted numbers unrelated to the
  # real findings (observed 2026-06-12: issue #42 review MEDIUM:3/LOW:3 logged
  # as medium=1/low=1; issue #43 CRITICAL:0 logged as critical=1 — phantom
  # CRITICAL clusters that corrupt every health-report aggregation). The JSON
  # block is present in all current reviews; the Findings fallback is kept
  # emoji-tolerant for any review that lacks it.
  _REVIEW_JSON_BLOCK=$(echo "$REVIEW_OUTPUT" | sed -n "/<!-- ${RITE_MARKER_REVIEW_DATA}/,/-->/p" | sed '1d;$d' || true)
  FINDINGS_LINE=$(echo "$REVIEW_OUTPUT" | grep -E "CRITICAL: *[0-9]+.*HIGH: *[0-9]+.*MEDIUM: *[0-9]+.*LOW: *[0-9]+" | head -1 || true)
  if [ -n "$_REVIEW_JSON_BLOCK" ] && echo "$_REVIEW_JSON_BLOCK" | jq -e '.summary' >/dev/null 2>&1; then
    CRITICAL_COUNT=$(echo "$_REVIEW_JSON_BLOCK" | jq -r '.summary.critical // 0')
    HIGH_COUNT=$(echo "$_REVIEW_JSON_BLOCK" | jq -r '.summary.high // 0')
    MEDIUM_COUNT=$(echo "$_REVIEW_JSON_BLOCK" | jq -r '.summary.medium // 0')
    LOW_COUNT=$(echo "$_REVIEW_JSON_BLOCK" | jq -r '.summary.low // 0')
  elif [ -n "$FINDINGS_LINE" ]; then
    CRITICAL_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "CRITICAL: *[0-9]+" | grep -oE "[0-9]+" | head -1 || echo "0")
    HIGH_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "HIGH: *[0-9]+" | grep -oE "[0-9]+" | head -1 || echo "0")
    MEDIUM_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "MEDIUM: *[0-9]+" | grep -oE "[0-9]+" | head -1 || echo "0")
    LOW_COUNT=$(echo "$FINDINGS_LINE" | grep -oE "LOW: *[0-9]+" | grep -oE "[0-9]+" | head -1 || echo "0")
  else
    # Last-resort fallback: count section headers (least reliable).
    CRITICAL_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*critical|❌.*critical" || true)
    HIGH_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*high|⚡.*high priority" || true)
    MEDIUM_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*medium|📋.*medium priority" || true)
    LOW_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### .*low|💡.*low|minor suggestion" || true)
  fi

  # Diagnostic logging for health reports
  _diag "REVIEW issue=${ISSUE_NUMBER:-?} critical=${CRITICAL_COUNT:-0} high=${HIGH_COUNT:-0} medium=${MEDIUM_COUNT:-0} low=${LOW_COUNT:-0}"

  # Triage gate — SHADOW mode only: classify this diff and log the verdict
  # paired with the opus findings just computed. The opus review above already
  # ran; this changes nothing, it only measures (calibration window). See
  # _triage_emit_shadow + "Triage Gate" in behavioral-design.md.
  if [ "${RITE_REVIEW_TRIAGE:-off}" = "shadow" ]; then
    _triage_emit_shadow "$PR_NUMBER" "$PR_DIFF" "${DIFF_FILES:-0}" \
      "${CRITICAL_COUNT:-0}" "${HIGH_COUNT:-0}" "${MEDIUM_COUNT:-0}" "${LOW_COUNT:-0}" || true
  fi

  # Post as PR comment (via temp file to avoid shell interpretation of
  # backticks and $() in code blocks within the review content)
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    print_status "Posting review for issue #$ISSUE_NUMBER..."
  else
    print_status "Posting review to PR #$PR_NUMBER..."
  fi

  COMMENT_FILE=$(mktemp)
  printf '%s' "$REVIEW_COMMENT" > "$COMMENT_FILE"

  # gh_safe handles transient 5xx/429 retries internally
  set +e
  REVIEW_RESULT=$(gh_safe pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE" 2>&1)
  POST_RC=$?
  set -e
  rm -f "$COMMENT_FILE"

  if [ $POST_RC -ne 0 ]; then
    if [ -n "${ISSUE_NUMBER:-}" ]; then
      print_error "Failed to post review for issue #$ISSUE_NUMBER"
    else
      print_error "Failed to post review to PR #$PR_NUMBER"
    fi
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
