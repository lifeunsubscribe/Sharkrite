#!/bin/bash
# lib/utils/review-assessment.sh
# Simplified review extraction for Claude to assess
# Sources this file to use assess_pr_review() function
#
# Expects config.sh to be already loaded

set -euo pipefail

# Bash 4+ re-exec guard (issue #1361 fallout — see #1374).
#
# lib/utils/gate-runners.sh nests `case` statements inside process
# substitutions, which bash 3.2 cannot parse, so it refuses to load under 3.2.
# On macOS /bin/bash IS 3.2, so any #!/bin/bash file that reaches it — directly
# or through test-gate.sh / gate-verdict.sh — dies before doing any work.
#
# #1374 guarded the five entry points known at the time and missed the rest:
# create-pr.sh then died the same way one phase later. Rather than chase them
# one at a time, every executable #!/bin/bash file in lib/ now carries this.
# It is inert when the file is sourced (the BASH_SOURCE test is false), so it
# costs nothing for the ones that are only ever libraries.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "${BASH:-}" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# Re-source guard — variable-based (not function-sentinel) because this file
# `export -f`s its functions; see blocker-rules.sh for the full rationale and
# tests/regression/blocker-rules-stale-inherited-functions.bats for the trap.
# Do NOT export _RITE_REVIEW_ASSESSMENT_LOADED — subprocesses must re-source.
if [ "${_RITE_REVIEW_ASSESSMENT_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_REVIEW_ASSESSMENT_LOADED=true

# Source gh retry wrapper and marker constants if not already loaded
_REVIEW_ASSESSMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$_REVIEW_ASSESSMENT_DIR/gh-retry.sh"
fi
source "$_REVIEW_ASSESSMENT_DIR/markers.sh"

# Function: assess_pr_review
# Extracts latest review and saves it for Claude assessment
# Usage: assess_pr_review <pr-number>
# Returns: 0=success, 1=error, 2=no review, 3=invalid format
assess_pr_review() {
  local PR_NUMBER=$1

  if [ -z "$PR_NUMBER" ]; then
    echo "❌ PR number required"
    return 1
  fi

  # Validate PR_NUMBER is numeric to prevent injection
  if [[ ! $PR_NUMBER =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid PR number: must be numeric"
    return 1
  fi

  # Colors
  local GREEN='\033[0;32m'
  local BLUE='\033[0;34m'
  local NC='\033[0m'

  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}📊 Review Assessment - PR #${PR_NUMBER}${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # Get the LATEST review only (match by body marker, not author — avoids picking up
  # assessment or other bot comments). Sorted by createdAt to ensure newest first.
  local LATEST_REVIEW _jq_latest_review_f
  _jq_latest_review_f="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].body"
  LATEST_REVIEW=$(gh_safe pr view "$PR_NUMBER" --json comments \
    --jq "$_jq_latest_review_f" \
    || true)
  LATEST_REVIEW="${LATEST_REVIEW:-}"

  # Validate gh CLI returned valid data
  if [ -z "$LATEST_REVIEW" ] || [ "$LATEST_REVIEW" = "null" ]; then
    echo "⚠️  No review found"
    return 2  # Exit code 2: no review available
  fi

  # Validate this is actually a code review (not arbitrary bot comment)
  # Accept: section markers OR sharkrite local review marker
  if ! echo "$LATEST_REVIEW" | grep -qiE "##? Code Review|##+ Overview|${RITE_MARKER_REVIEW}"; then
    echo "⚠️  Comment found but doesn't appear to be a code review"
    echo "   (Missing 'Code Review' or 'Overview' section markers)"
    return 3  # Exit code 3: invalid format
  fi

  echo -e "${GREEN}✅ Review received${NC}"
  echo ""
  echo "PR #${PR_NUMBER} ready for assessment"
  echo ""

  return 0
}

# Export function if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f assess_pr_review
fi
