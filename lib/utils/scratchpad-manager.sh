#!/bin/bash
# lib/utils/scratchpad-manager.sh
# Manage scratchpad lifecycle: read security findings, update after PR merge
# Usage: source this file and call functions
#
# Requires: config.sh sourced (for SCRATCHPAD_FILE, RITE_INSTALL_DIR)

# Use configured scratchpad path (set by config.sh)
SCRATCHPAD_FILE="${SCRATCHPAD_FILE:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md}"

# Update scratchpad with security findings from PR review
update_scratchpad_from_pr() {
  local pr_number="$1"
  local pr_title="${2:-PR #$pr_number}"

  if [ ! -f "$SCRATCHPAD_FILE" ]; then
    echo "Scratchpad not found: $SCRATCHPAD_FILE" >&2
    return 1
  fi

  echo "Updating scratchpad with PR #$pr_number findings..."

  # Get PR review
  local review_body=$(gh pr view "$pr_number" --json comments --jq '[.comments[] | select(.author.login == "claude" or .author.login == "claude[bot]" or .author.login == "github-actions[bot]")] | .[-1].body' 2>/dev/null || echo "")

  if [ -z "$review_body" ] || [ "$review_body" = "null" ]; then
    echo "No review found for PR #$pr_number"
    return 0
  fi

  # Extract security-related issues (CRITICAL, HIGH, MEDIUM with security keywords)
  local security_findings=$(echo "$review_body" | grep -A 5 -iE "(CRITICAL|HIGH|MEDIUM).*(security|auth|tenant|validation|sql|xss|csrf|injection|leak)" | head -50 || echo "")

  if [ -z "$security_findings" ]; then
    echo "No security findings in PR #$pr_number review"
    # Still update to record that this PR was processed
    security_findings="No significant security issues found"
  fi

  # Create new entry
  local new_entry="### PR #$pr_number: $pr_title ($(date '+%Y-%m-%d'))

$security_findings

---
"

  # Create temp file for reconstruction
  local temp_file=$(mktemp)

  # Check if scratchpad has proper structure
  if ! grep -q "## Recent Security Findings" "$SCRATCHPAD_FILE"; then
    # Add structure if missing
    cat >> "$SCRATCHPAD_FILE" <<EOF

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Sharkrite updates this automatically._

EOF
  fi

  # Extract sections
  local before_recent=$(sed -n '1,/## Recent Security Findings/p' "$SCRATCHPAD_FILE")
  local after_recent=$(sed -n '/## Recent Security Findings/,/## /p' "$SCRATCHPAD_FILE" | tail -n +2)
  local after_archive=$(sed -n '/## Completed Work Archive/,$p' "$SCRATCHPAD_FILE")

  # Get existing entries (up to 4, since we're adding 1 new = 5 total)
  local existing_entries=$(echo "$after_recent" | sed '/^## /Q' | grep -A 9999 "^### PR #" | head -c 5000 || echo "")

  # Count existing entries
  local entry_count=$(echo "$existing_entries" | grep -c "^### PR #" || true)

  # Keep only last 4 entries if we have 5+ (since we're adding new one)
  if [ "$entry_count" -ge 4 ]; then
    existing_entries=$(echo "$existing_entries" | awk '/^### PR #/{n++} n<=4' || echo "")
  fi

  # Reconstruct scratchpad
  cat > "$temp_file" <<EOF
$before_recent

$new_entry
$existing_entries

## Completed Work Archive

_Last 20 PRs — auto-cleaned_

$after_archive
EOF

  # Archive management: keep last 20 entries in archive
  if grep -q "## Completed Work Archive" "$temp_file"; then
    local archive_count=$(sed -n '/## Completed Work Archive/,/^## /p' "$temp_file" | grep -c "^### PR #" || true)

    if [ "$archive_count" -gt 20 ]; then
      echo "Trimming archive to last 20 entries"
    fi
  fi

  # Apply update
  mv "$temp_file" "$SCRATCHPAD_FILE"

  echo "Scratchpad updated - PR #$pr_number added to Recent Security Findings"

  return 0
}

# Clear "Current Work" section after PR merge
clear_current_work() {
  if [ ! -f "$SCRATCHPAD_FILE" ]; then
    return 0
  fi

  echo "Clearing Current Work section..."

  local temp_file=$(mktemp)

  # Remove content between "## Current Work" and next "##"
  sed '/## Current Work/,/^## /{/## Current Work/!{/^## /!d;}}' "$SCRATCHPAD_FILE" > "$temp_file"

  # Add empty Current Work section (portable: works on both GNU and BSD sed)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' '/## Current Work/a\
\
_No active work — run `rite <issue>` to start_\
' "$temp_file"
  else
    sed -i '/## Current Work/a\\n_No active work — run `rite <issue>` to start_\n' "$temp_file"
  fi

  mv "$temp_file" "$SCRATCHPAD_FILE"

  echo "Current Work section cleared"
}

# Initialize scratchpad structure if missing
# Uses template from $RITE_INSTALL_DIR/templates/scratchpad.md
init_scratchpad() {
  if [ ! -f "$SCRATCHPAD_FILE" ]; then
    # Copy from template if available, otherwise create minimal structure
    if [ -f "$RITE_INSTALL_DIR/templates/scratchpad.md" ]; then
      cp "$RITE_INSTALL_DIR/templates/scratchpad.md" "$SCRATCHPAD_FILE"
    else
      # Minimal fallback if template not found
      cat > "$SCRATCHPAD_FILE" <<'EOF'
# Sharkrite Scratchpad

**Purpose:** Working notes, security findings, and development context

---

## Current Work

_No active work — run `rite <issue>` to start_

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Sharkrite updates this automatically._

---

## Completed Work Archive

_Last 20 PRs — auto-cleaned_

---

_This file is gitignored. It persists locally for your development context._
EOF
    fi

    echo "Scratchpad initialized: $SCRATCHPAD_FILE"
  fi
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f update_scratchpad_from_pr
  export -f clear_current_work
  export -f init_scratchpad
fi
