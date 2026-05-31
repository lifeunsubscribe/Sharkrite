#!/bin/bash
# pr-summary.sh
# Helpers for the marked changes-summary section in PR descriptions.
# The section lives between <!-- sharkrite-changes-summary --> markers
# and is visible on GitHub (only the marker lines are hidden).

set -euo pipefail

SUMMARY_START="<!-- sharkrite-changes-summary -->"
SUMMARY_END="<!-- /sharkrite-changes-summary -->"

# build_changes_summary BASE_BRANCH
# Generates the full marked section from current git state.
# Must be called from within the repo/worktree.
build_changes_summary() {
  local base_branch="${1:-main}"

  local commit_log files_changed
  commit_log=$(git log --oneline "origin/${base_branch}..HEAD" 2>/dev/null || git log --oneline -5)
  files_changed=$(git diff --name-status "origin/${base_branch}..HEAD" 2>/dev/null || git diff --name-status HEAD~1..HEAD)

  local commit_count file_count files_added files_modified files_deleted
  commit_count=$(echo "$commit_log" | grep -c '.' || true)
  file_count=$(echo "$files_changed" | grep -c '.' || true)
  files_added=$(echo "$files_changed" | grep -c '^A' || true)
  files_modified=$(echo "$files_changed" | grep -c '^M' || true)
  files_deleted=$(echo "$files_changed" | grep -c '^D' || true)

  local summary="$SUMMARY_START
## Changes

**${file_count}** files, **${commit_count}** commits (+${files_added} added, ~${files_modified} modified, -${files_deleted} deleted)
"

  # File list (truncate at 50)
  local shown=0
  while IFS=$'\t' read -r status file; do
    [ -z "$status" ] && continue
    summary+="- \`${status}\` ${file}
"
    shown=$((shown + 1))
    if [ "$shown" -ge 50 ]; then
      local remaining=$((file_count - 50))
      summary+="- ... and ${remaining} more
"
      break
    fi
  done <<< "$files_changed"

  summary+="
### Commits
"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    summary+="- ${line}
"
  done <<< "$commit_log"

  summary+="$SUMMARY_END"
  echo "$summary"
}

# extract_changes_summary PR_BODY
# Extracts content between markers (excluding markers themselves).
# Returns 1 if markers not found.
extract_changes_summary() {
  local pr_body="$1"

  if ! echo "$pr_body" | grep -qF "$SUMMARY_START"; then
    return 1
  fi

  # Use escaped end marker (contains / which is sed's delimiter)
  local end_escaped="${SUMMARY_END//\//\\/}"
  echo "$pr_body" | sed -n "/${SUMMARY_START}/,/${end_escaped}/p" | sed '1d;$d'
}

# replace_changes_summary EXISTING_BODY NEW_SUMMARY
# Replaces the marked section in the body. If no markers exist, inserts
# after the first blank line following "## Summary".
replace_changes_summary() {
  local existing_body="$1"
  local new_summary="$2"

  if echo "$existing_body" | grep -qF "$SUMMARY_START"; then
    # Delete old section (markers inclusive), insert new section
    local before after
    before=$(echo "$existing_body" | sed "/${SUMMARY_START}/,\$d")
    after=$(echo "$existing_body" | sed "1,/${SUMMARY_END//\//\\/}/d")
    printf '%s\n\n%s\n\n%s' "$before" "$new_summary" "$after"
  else
    # No markers — insert after "## Summary" paragraph
    local inserted=false
    local past_header=false
    local result=""

    while IFS= read -r line; do
      result+="${line}
"
      if [[ "$line" == "## Summary"* ]]; then
        past_header=true
      fi
      # Insert after the first blank line that follows a non-blank line after ## Summary
      if [ "$past_header" = true ] && [ "$inserted" = false ] && [ -z "$line" ]; then
        # Check if next content starts (we've passed the summary paragraph)
        result+="${new_summary}

"
        inserted=true
      fi
    done <<< "$existing_body"

    if [ "$inserted" = false ]; then
      result+="
${new_summary}
"
    fi

    echo "$result"
  fi
}
