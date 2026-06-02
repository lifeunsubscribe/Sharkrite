#!/bin/bash
# lib/utils/format-review.sh
# Formats PR review markdown into compact, readable format
# Usage: format-review.sh <review_file>

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

set -euo pipefail

REVIEW_FILE="$1"

if [ ! -f "$REVIEW_FILE" ]; then
  echo "Error: Review file not found: $REVIEW_FILE" >&2
  exit 1
fi

# State machine variables
IN_CODE_BLOCK=false
IN_LIST=false
LIST_BUFFER=()
CURRENT_SECTION=""
PENDING_SUBHEADER=""

# Extract just the key phrase from a list item (first few words before colon or dash)
extract_key_phrase() {
  local item="$1"
  # Remove markdown formatting
  item=$(echo "$item" | sed -E 's/\*\*//g' | sed -E 's/__//g' | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Extract key phrase (text before : or - or first sentence)
  if [[ "$item" =~ ^([^:—-]+)[:\—-] ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    # Take first 5 words max
    echo "$item" | cut -d' ' -f1-5
  fi
}

process_line() {
  local line="$1"

  # Handle code blocks - just skip them entirely
  if [[ "$line" =~ ^'```' ]]; then
    flush_list
    if [ "$IN_CODE_BLOCK" = false ]; then
      IN_CODE_BLOCK=true
    else
      IN_CODE_BLOCK=false
    fi
    return
  fi

  # Skip lines inside code blocks
  if [ "$IN_CODE_BLOCK" = true ]; then
    return
  fi

  # Skip horizontal rules
  if [[ "$line" =~ ^-{3,}$ ]] || [[ "$line" =~ ^={3,}$ ]] || [[ "$line" =~ ^━{3,}$ ]]; then
    return
  fi

  # Handle main headers (## Title) - skip them (already shown in assess-and-resolve header)
  if [[ "$line" =~ ^##[[:space:]](.+)$ ]]; then
    flush_list
    local title="${BASH_REMATCH[1]}"

    # First header (usually "Code Review - PR #XX") - skip it (shown in header)
    if [ -z "$CURRENT_SECTION" ]; then
      CURRENT_SECTION="title"
      return
    fi

    # Subsequent headers - don't convert, they're handled by ### headers
    return
  fi

  # Handle subheaders (### or ####)
  if [[ "$line" =~ ^###[#]*[[:space:]](.+)$ ]]; then
    flush_list
    local subtitle="${BASH_REMATCH[1]}"

    # Remove bold/italic and clean
    subtitle=$(echo "$subtitle" | sed -E 's/\*\*//g' | sed -E 's/__//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Extract emoji if present
    local emoji=""
    if [[ "$subtitle" =~ ^([[:space:]]*[^[:alnum:][:space:]]+)[[:space:]]*(.+)$ ]]; then
      emoji="${BASH_REMATCH[1]} "
      subtitle="${BASH_REMATCH[2]}"
    fi

    # Map sections to emojis and set current section
    echo ""  # Blank line before section
    case "$subtitle" in
      *Summary*|*SUMMARY*)
        echo "✏️ Summary:"
        CURRENT_SECTION="summary"
        ;;
      *Strength*|*STRENGTHS*)
        echo "💪 Strengths:"
        CURRENT_SECTION="strengths"
        ;;
      *Code*Quality*|*CODE*QUALITY*)
        echo "📋 Code Quality Assessment:"
        CURRENT_SECTION="code_quality"
        ;;
      *Detail*Review*|*DETAILED*REVIEW*)
        echo "🔍 Detailed Review:"
        CURRENT_SECTION="detailed"
        ;;
      *Suggestion*|*SUGGESTIONS*|*Minor*Suggestion*)
        echo "💡 Minor Suggestions:"
        CURRENT_SECTION="suggestions"
        ;;
      *Security*|*SECURITY*)
        echo "🔒 Security Review:"
        CURRENT_SECTION="security"
        ;;
      *Test*|*TESTING*|*TEST*COVERAGE*)
        echo "🧪 Test Coverage:"
        CURRENT_SECTION="tests"
        ;;
      *Performance*|*PERFORMANCE*)
        echo "📊 Performance:"
        CURRENT_SECTION="performance"
        ;;
      *Alignment*|*CLAUDE.md*)
        echo "🎯 Alignment with project guidelines:"
        CURRENT_SECTION="alignment"
        ;;
      *CRITICAL*|*Critical*)
        echo "🚨 CRITICAL Issues:"
        CURRENT_SECTION="critical"
        ;;
      *HIGH*|*High*)
        echo "⚡ HIGH Priority Issues:"
        CURRENT_SECTION="high"
        ;;
      *MEDIUM*|*Medium*)
        echo "📋 MEDIUM Priority Issues:"
        CURRENT_SECTION="medium"
        ;;
      *LOW*|*Low*)
        echo "💡 LOW Priority Issues:"
        CURRENT_SECTION="low"
        ;;
      *)
        # Store subheader for later (might be a parenthetical note)
        PENDING_SUBHEADER="$subtitle"
        ;;
    esac
    return
  fi

  # Handle bullet/numbered lists
  if [[ "$line" =~ ^[[:space:]]*[-*•][[:space:]]+(.+)$ ]] || [[ "$line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+(.+)$ ]]; then
    local item="${BASH_REMATCH[1]}"

    case "$CURRENT_SECTION" in
      strengths)
        # Extract just key phrase for strengths
        local key=$(extract_key_phrase "$item")
        LIST_BUFFER+=("$key")
        IN_LIST=true
        ;;
      alignment)
        # Remove markdown
        item=$(echo "$item" | sed -E 's/\*\*//g' | sed -E 's/__//g')
        echo "— $item"
        ;;
      *)
        # Other lists: keep compact
        item=$(echo "$item" | sed -E 's/\*\*//g' | sed -E 's/__//g')
        echo "  • $item"
        ;;
    esac
    return
  fi

  # Handle regular text
  if [[ -n "$line" ]]; then
    flush_list

    # Print pending subheader if exists
    if [ -n "$PENDING_SUBHEADER" ]; then
      echo "($PENDING_SUBHEADER) $line"
      PENDING_SUBHEADER=""
      return
    fi

    # Remove markdown formatting
    local clean_line=$(echo "$line" | sed -E 's/\*\*//g' | sed -E 's/__//g')

    # Skip pure whitespace
    if [[ "$clean_line" =~ ^[[:space:]]*$ ]]; then
      return
    fi

    echo "$clean_line"
  fi
}

flush_list() {
  if [ "$IN_LIST" = true ] && [ ${#LIST_BUFFER[@]} -gt 0 ]; then
    case "$CURRENT_SECTION" in
      strengths)
        # Join with comma-space separator
        printf "%s" "${LIST_BUFFER[0]}"
        for i in "${LIST_BUFFER[@]:1}"; do
          printf ", %s" "$i"
        done
        echo ""
        ;;
    esac
    LIST_BUFFER=()
    IN_LIST=false
  fi
}

# Read and process file
while IFS= read -r line || [ -n "$line" ]; do
  process_line "$line"
done < "$REVIEW_FILE"

# Final flush
flush_list
