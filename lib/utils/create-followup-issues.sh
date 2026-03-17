#!/bin/bash
# lib/utils/create-followup-issues.sh
# Creates GitHub issues from PR review "skip" items
# Usage: source this file and call create_followup_issues <pr-number>
#
# Expects config.sh to be already loaded

# Function: create_followup_issues
# Parses latest review for "skip" items and creates GitHub issues
# Returns: 0 on success, number of issues created stored in ISSUES_CREATED global
create_followup_issues() {
  local PR_NUMBER=$1
  local PR_TITLE=$2

  if [ -z "$PR_NUMBER" ]; then
    echo "❌ PR number required"
    return 1
  fi

  # Get latest review
  local LATEST_REVIEW=$(gh pr view "$PR_NUMBER" --json comments \
    --jq '[.comments[] | select(.author.login == "github-actions[bot]" or .author.login == "claude" or .author.login == "claude-code")] | .[-1] | .body' \
    2>/dev/null)

  if [ -z "$LATEST_REVIEW" ]; then
    echo "⚠️  No review found, skipping issue creation"
    return 0
  fi

  # Parse review for "Skip" items with details
  # Look for patterns like:
  # "→ Skip - <reason>"
  # Extract: priority, issue title, location, problem, why it matters

  local TEMP_REVIEW=$(mktemp)
  echo "$LATEST_REVIEW" > "$TEMP_REVIEW"

  # Array to store created issue numbers
  CREATED_ISSUES=()

  # Parse each priority section
  local CURRENT_PRIORITY=""
  local CURRENT_ISSUE_NUM=0
  local CURRENT_ISSUE_TITLE=""
  local CURRENT_LOCATION=""
  local CURRENT_PROBLEM=""
  local CURRENT_WHY=""
  local CURRENT_RECOMMENDATION=""
  local IN_SKIP_ITEM=false

  while IFS= read -r line; do
    # Detect priority sections
    if [[ "$line" =~ ^###[[:space:]]+(HIGH|MEDIUM|LOW)[[:space:]]+Priority ]]; then
      CURRENT_PRIORITY="${BASH_REMATCH[1]}"
      continue
    fi

    # Detect issue numbers (e.g., "#### 4." or "**4.**" or "Issue #4:")
    if [[ "$line" =~ (####|Issue[[:space:]]*#|^\*\*)[[:space:]]*([0-9]+)[\.\):] ]]; then
      CURRENT_ISSUE_NUM="${BASH_REMATCH[2]}"
      # Extract title from same line or next
      CURRENT_ISSUE_TITLE=$(echo "$line" | sed -E 's/^(####|Issue[[:space:]]*#|\*\*)[[:space:]]*[0-9]+[\.\):]?[[:space:]]*//' | sed 's/\*\*//g')
      IN_SKIP_ITEM=false
      continue
    fi

    # Extract location
    if [[ "$line" =~ ^\*\*Location:\*\*[[:space:]]*(.*) ]]; then
      CURRENT_LOCATION="${BASH_REMATCH[1]}"
      continue
    fi

    # Extract problem
    if [[ "$line" =~ ^\*\*Problem:\*\*[[:space:]]*(.*) ]] || [[ "$line" =~ ^\*\*Issue:\*\*[[:space:]]*(.*) ]]; then
      CURRENT_PROBLEM="${BASH_REMATCH[1]}"
      continue
    fi

    # Extract why it matters
    if [[ "$line" =~ ^\*\*Why[[:space:]]it[[:space:]]matters:\*\*[[:space:]]*(.*) ]]; then
      CURRENT_WHY="${BASH_REMATCH[1]}"
      continue
    fi

    # Extract recommendation
    if [[ "$line" =~ ^\*\*Recommendation:\*\*[[:space:]]*(.*) ]]; then
      CURRENT_RECOMMENDATION="${BASH_REMATCH[1]}"
      continue
    fi

    # Check for "Skip" verdict
    if [[ "$line" =~ →[[:space:]]Skip ]] || [[ "$line" =~ ^\*\*Verdict:\*\*[[:space:]]*Skip ]]; then
      IN_SKIP_ITEM=true

      # We have all the details, create an issue
      if [ -n "$CURRENT_ISSUE_TITLE" ] && [ -n "$CURRENT_PRIORITY" ]; then
        create_single_issue "$PR_NUMBER" "$PR_TITLE" "$CURRENT_PRIORITY" \
          "$CURRENT_ISSUE_TITLE" "$CURRENT_LOCATION" "$CURRENT_PROBLEM" \
          "$CURRENT_WHY" "$CURRENT_RECOMMENDATION"

        if [ $? -eq 0 ]; then
          CREATED_ISSUES+=("$NEW_ISSUE_NUMBER")
        fi
      fi

      # Reset for next issue
      CURRENT_ISSUE_TITLE=""
      CURRENT_LOCATION=""
      CURRENT_PROBLEM=""
      CURRENT_WHY=""
      CURRENT_RECOMMENDATION=""
    fi

  done < "$TEMP_REVIEW"

  rm -f "$TEMP_REVIEW"

  # Export created issues for caller
  export ISSUES_CREATED="${CREATED_ISSUES[@]}"
  export ISSUES_CREATED_COUNT="${#CREATED_ISSUES[@]}"

  return 0
}

# Helper: Create a single GitHub issue
create_single_issue() {
  local PR_NUMBER=$1
  local PR_TITLE=$2
  local PRIORITY=$3
  local ISSUE_TITLE=$4
  local LOCATION=$5
  local PROBLEM=$6
  local WHY=$7
  local RECOMMENDATION=$8

  # Map priority to labels
  local PRIORITY_LABEL=""
  case "$PRIORITY" in
    HIGH)
      PRIORITY_LABEL="High Priority"
      ;;
    MEDIUM)
      PRIORITY_LABEL="Medium Priority"
      ;;
    LOW)
      PRIORITY_LABEL="Low Priority"
      ;;
  esac

  # Determine type label from title/location
  local TYPE_LABEL=""
  if [[ "$ISSUE_TITLE" =~ [Dd]ocument ]] || [[ "$ISSUE_TITLE" =~ [Dd]oc ]]; then
    TYPE_LABEL="documentation"
  elif [[ "$ISSUE_TITLE" =~ [Tt]est ]] || [[ "$LOCATION" =~ test ]]; then
    TYPE_LABEL="testing"
  elif [[ "$ISSUE_TITLE" =~ [Rr]efactor ]] || [[ "$ISSUE_TITLE" =~ [Cc]omplex ]]; then
    TYPE_LABEL="enhancement"
  elif [[ "$LOCATION" =~ infrastructure ]] || [[ "$LOCATION" =~ deploy ]]; then
    TYPE_LABEL="infrastructure"
  else
    TYPE_LABEL="enhancement"
  fi

  # Build issue body
  local ISSUE_BODY=$(cat <<EOF
## From PR Review
PR #${PR_NUMBER} - ${PR_TITLE}

## Priority
${PRIORITY}

$([ -n "$LOCATION" ] && echo "## Location
\`${LOCATION}\`

")## Issue
${PROBLEM}

## Why It Matters
${WHY}

$([ -n "$RECOMMENDATION" ] && echo "## Recommendation
${RECOMMENDATION}

")## Acceptance Criteria
- [ ] Issue addressed
- [ ] Tests updated if applicable
- [ ] Documentation updated if applicable
EOF
)

  # Create the issue (via temp file to avoid shell metacharacter issues)
  local body_file
  body_file=$(mktemp)
  printf '%s' "$ISSUE_BODY" > "$body_file"
  NEW_ISSUE_NUMBER=$(gh issue create \
    --title "$ISSUE_TITLE" \
    --body-file "$body_file" \
    --label "pr-review" \
    --label "$PRIORITY_LABEL" \
    --label "$TYPE_LABEL" \
    --json number \
    --jq '.number' 2>/dev/null)
  rm -f "$body_file"

  if [ -n "$NEW_ISSUE_NUMBER" ]; then
    echo "✅ Created issue #$NEW_ISSUE_NUMBER: $ISSUE_TITLE"
    export NEW_ISSUE_NUMBER
    return 0
  else
    echo "❌ Failed to create issue: $ISSUE_TITLE"
    return 1
  fi
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f create_followup_issues
  export -f create_single_issue
fi
