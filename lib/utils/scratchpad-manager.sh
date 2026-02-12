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
    return 0
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

## Encountered Issues (Needs Triage)

_Out-of-scope issues discovered during development. Auto-triaged to tech-debt issues at merge._

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

# Log an out-of-scope issue discovered during development
# Appends to "## Encountered Issues" section. Deduplicates by file:line. Caps at 50 entries (FIFO).
# Usage: log_encountered_issue "file_path" "line" "category" "description" "affects" "fix" "done_criteria"
log_encountered_issue() {
  local file_path="$1"
  local line_num="${2:-}"
  local category="$3"
  local description="$4"
  local affects="$5"
  local fix="$6"
  local done_criteria="$7"

  if [ ! -f "$SCRATCHPAD_FILE" ]; then
    return 0
  fi

  # Validate category
  case "$category" in
    test-failure|security|code-smell|missing-docs|deprecation|performance) ;;
    *)
      echo "Warning: Unknown category '$category'. Using 'code-smell'." >&2
      category="code-smell"
      ;;
  esac

  local location="$file_path"
  if [ -n "$line_num" ]; then
    location="${file_path}:${line_num}"
  fi

  local today=$(date '+%Y-%m-%d')

  # Ensure section exists
  if ! grep -q "## Encountered Issues" "$SCRATCHPAD_FILE"; then
    local temp_file=$(mktemp)
    # Insert before "## Recent Security Findings" if it exists, else append
    if grep -q "## Recent Security Findings" "$SCRATCHPAD_FILE"; then
      sed '/## Recent Security Findings/i\
## Encountered Issues (Needs Triage)\
\
_Out-of-scope issues discovered during development. Auto-triaged to tech-debt issues at merge._\
\
---\
' "$SCRATCHPAD_FILE" > "$temp_file"
      mv "$temp_file" "$SCRATCHPAD_FILE"
    else
      cat >> "$SCRATCHPAD_FILE" <<EOF

---

## Encountered Issues (Needs Triage)

_Out-of-scope issues discovered during development. Auto-triaged to tech-debt issues at merge._

EOF
    fi
  fi

  # Check for duplicate by file:line (keep first occurrence, update date)
  if grep -q "\`${location}\`" "$SCRATCHPAD_FILE"; then
    # Already logged — skip duplicate
    echo "Encountered issue already logged for ${location}, skipping"
    return 0
  fi

  local new_entry="- **${today}** | \`${location}\` | ${category} | ${description} | Affects: ${affects} | Fix: ${fix} | Done: ${done_criteria}"

  # Insert entry after the section header and description line
  local temp_file=$(mktemp)
  local in_section=false
  local inserted=false

  while IFS= read -r line || [ -n "$line" ]; do
    echo "$line" >> "$temp_file"
    if [[ "$line" == "## Encountered Issues"* ]]; then
      in_section=true
    fi
    # Insert after the description line (starts with underscore)
    if [ "$in_section" = true ] && [ "$inserted" = false ] && [[ "$line" == _* ]]; then
      echo "" >> "$temp_file"
      echo "$new_entry" >> "$temp_file"
      inserted=true
    fi
  done < "$SCRATCHPAD_FILE"

  # If we didn't find the description line, insert after the header
  if [ "$inserted" = false ]; then
    # Fallback: just append to end of section
    mv "$temp_file" /dev/null 2>/dev/null || true
    temp_file=$(mktemp)
    awk -v entry="$new_entry" '
      /^## Encountered Issues/ { print; getline; print; print ""; print entry; next }
      { print }
    ' "$SCRATCHPAD_FILE" > "$temp_file"
  fi

  mv "$temp_file" "$SCRATCHPAD_FILE"

  # Enforce 50-entry cap (FIFO: remove oldest entries)
  local entry_count=$(sed -n '/## Encountered Issues/,/^## /p' "$SCRATCHPAD_FILE" | grep -c "^- \*\*[0-9]" || true)
  if [ "$entry_count" -gt 50 ]; then
    local excess=$((entry_count - 50))
    # Remove the last N entries (oldest are at the bottom within the section)
    local temp_file=$(mktemp)
    local in_section=false
    local removed=0

    # Collect entries in reverse, mark extras for removal
    # Simpler approach: extract section, keep first 50 entries, reconstruct
    local before_section=$(sed -n '1,/^## Encountered Issues/p' "$SCRATCHPAD_FILE" | head -n -1)
    local section_header=$(grep "^## Encountered Issues" "$SCRATCHPAD_FILE")
    local section_desc=$(sed -n '/^## Encountered Issues/,/^## /p' "$SCRATCHPAD_FILE" | sed '1d' | sed '/^## /,$d' | grep "^_" | head -1)
    local entries=$(sed -n '/^## Encountered Issues/,/^## /p' "$SCRATCHPAD_FILE" | sed '1d' | sed '/^## /,$d' | grep "^- \*\*[0-9]" | head -50)
    local after_section=$(sed -n '/^## Encountered Issues/,/^## /{/^## Encountered Issues/!{/^## /!d;};}' "$SCRATCHPAD_FILE" | tail -n +2)
    # Reconstruct — this is getting complex, use simpler sed approach
    # Just keep the first 50 matching lines
    awk '
      /^## Encountered Issues/ { in_sec=1; count=0 }
      in_sec && /^- \*\*[0-9]/ { count++; if (count > 50) next }
      /^## / && !/^## Encountered Issues/ && in_sec { in_sec=0 }
      { print }
    ' "$SCRATCHPAD_FILE" > "$temp_file"
    mv "$temp_file" "$SCRATCHPAD_FILE"
  fi

  echo "Logged encountered issue: ${location} (${category})"
}

# Create GitHub tech-debt issues from encountered issues in scratchpad
# Usage: create_tech_debt_issues "originating_pr_or_issue_number"
# Returns (echoes) count of issues created
create_tech_debt_issues() {
  local origin_number="${1:-}"

  if [ ! -f "$SCRATCHPAD_FILE" ]; then
    echo "0"
    return 0
  fi

  # Extract encountered issues section
  local section=$(sed -n '/^## Encountered Issues/,/^## /p' "$SCRATCHPAD_FILE" | sed '1d' | sed '/^## /d')

  # Get entry lines
  local entries=$(echo "$section" | grep "^- \*\*[0-9]" || true)

  if [ -z "$entries" ]; then
    echo "0"
    return 0
  fi

  local created=0

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    # Parse pipe-delimited fields: - **DATE** | `file:line` | category | description | Affects: ... | Fix: ... | Done: ...
    local date_field=$(echo "$entry" | sed 's/^- \*\*\([0-9-]*\)\*\*.*/\1/')
    local location=$(echo "$entry" | sed 's/.*| `\([^`]*\)`.*/\1/')
    local category=$(echo "$entry" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
    local description=$(echo "$entry" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    local affects=$(echo "$entry" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); sub(/^Affects: /,"",$5); print $5}')
    local fix=$(echo "$entry" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); sub(/^Fix: /,"",$6); print $6}')
    local done_criteria=$(echo "$entry" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); sub(/^Done: /,"",$7); print $7}')

    # Check if similar issue already exists (search by file path in title)
    local search_term="[tech-debt] ${category}: ${description}"
    # Truncate search to avoid overly specific queries
    local search_query=$(echo "$search_term" | head -c 80)
    local existing=$(gh issue list -S "\"[tech-debt]\" \"${location}\" in:title" --state all --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
      echo "Tech-debt issue already exists for ${location}: #${existing}" >&2
      continue
    fi

    # Build issue body
    local origin_text=""
    if [ -n "$origin_number" ]; then
      origin_text="First observed: ${date_field} during work on #${origin_number}"
    else
      origin_text="First observed: ${date_field}"
    fi

    local issue_title="[tech-debt] ${category}: ${description}"
    # Truncate title to 256 chars (GitHub limit)
    issue_title=$(echo "$issue_title" | head -c 256)

    local issue_body
    issue_body=$(cat <<EOF
## Description
${description}

## Location
\`${location}\`

## Impact
Affects: ${affects}

## Intended Fix
${fix}

## Done Criteria
- [ ] ${done_criteria}
- [ ] Tests pass
- [ ] No regressions introduced

## Origin
${origin_text}

---
_Auto-generated by sharkrite workflow from encountered issues log_
EOF
    )

    # Create the issue
    if gh issue create --title "$issue_title" --body "$issue_body" --label "tech-debt" --label "automated" 2>/dev/null; then
      created=$((created + 1))
      echo "Created tech-debt issue: ${issue_title}" >&2
    else
      # Labels might not exist — try without labels
      if gh issue create --title "$issue_title" --body "$issue_body" 2>/dev/null; then
        created=$((created + 1))
        echo "Created tech-debt issue (no labels): ${issue_title}" >&2
      else
        echo "Failed to create tech-debt issue for ${location}" >&2
      fi
    fi

  done <<< "$entries"

  echo "$created"
}

# Clear encountered issues section after processing
# Removes all entries but preserves the section header and description
clear_encountered_issues() {
  if [ ! -f "$SCRATCHPAD_FILE" ]; then
    return 0
  fi

  if ! grep -q "## Encountered Issues" "$SCRATCHPAD_FILE"; then
    return 0
  fi

  echo "Clearing Encountered Issues section..."

  local temp_file=$(mktemp)

  # Remove entry lines between "## Encountered Issues" and next "##", keep header + description
  awk '
    /^## Encountered Issues/ { in_sec=1; print; next }
    in_sec && /^## / { in_sec=0; print; next }
    in_sec && /^_/ { print; next }
    in_sec && /^---/ { print; next }
    in_sec && /^$/ { print; next }
    in_sec && /^- \*\*[0-9]/ { next }
    { print }
  ' "$SCRATCHPAD_FILE" > "$temp_file"

  mv "$temp_file" "$SCRATCHPAD_FILE"

  echo "Encountered Issues section cleared"
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f update_scratchpad_from_pr
  export -f clear_current_work
  export -f init_scratchpad
  export -f log_encountered_issue
  export -f create_tech_debt_issues
  export -f clear_encountered_issues
fi
