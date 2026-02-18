#!/bin/bash
# lib/utils/normalize-issue.sh - Issue title normalization and structured issue generation
#
# Produces two variables for downstream consumers:
#   NORMALIZED_SUBJECT  — Clean issue title (<=50 chars, imperative, no commit prefix)
#   WORK_DESCRIPTION    — Full context for Claude dev prompt and PR body
#
# Two paths:
#   normalize_piped_input "$text"  — Generate structured issue from freeform text via Claude
#   normalize_existing_issue       — Bash-only cleanup of existing issue title
#
# Path A prompts for approval before creating the GitHub issue.
# Path B auto-applies deterministic cleanup (no prompt).

# Source colors if not already loaded
if ! declare -f print_info &>/dev/null; then
  if [ -n "${RITE_LIB_DIR:-}" ]; then
    source "$RITE_LIB_DIR/utils/colors.sh"
  fi
fi

# Detect Claude CLI (consistent with claude-workflow.sh)
_detect_claude_cmd() {
  if command -v claude &>/dev/null; then
    echo "claude"
  elif command -v claude-code &>/dev/null; then
    echo "claude-code"
  elif [ -f "$HOME/.claude/claude" ]; then
    echo "$HOME/.claude/claude"
  else
    echo ""
  fi
}

# Truncate a string to max_len at a word boundary.
# Usage: _truncate_at_word_boundary "$string" max_len
_truncate_at_word_boundary() {
  local str="$1"
  local max_len="$2"

  if [ ${#str} -le "$max_len" ]; then
    echo "$str"
    return
  fi

  # Cut to max_len, then remove the last partial word
  local cut
  cut=$(echo "$str" | cut -c1-"$max_len")
  # If the cut lands mid-word, remove the trailing fragment
  if [ "${str:$max_len:1}" != " " ] && [ "${str:$max_len:1}" != "" ]; then
    cut=$(echo "$cut" | sed 's/ [^ ]*$//')
  fi
  echo "$cut"
}

# ===================================================================
# PATH A: Piped text instructions (rite "fix the rate limiter")
# ===================================================================
#
# Uses Claude to generate a structured GitHub issue from freeform text.
# Sets: NORMALIZED_SUBJECT, WORK_DESCRIPTION, ISSUE_NUMBER (after gh issue create)
# Returns: 0 on approval, 1 on rejection
normalize_piped_input() {
  local input_text="$1"

  local claude_cmd
  claude_cmd=$(_detect_claude_cmd)

  # Build the Claude prompt
  local prompt
  prompt="You are preparing a GitHub issue for an automated development workflow.

Given this task description:
---
${input_text}
---

Generate a structured GitHub issue. Make reasonable assumptions about implementation approach — the user will review and approve before work begins.

Output format (follow EXACTLY):

TITLE: <imperative mood, <=50 chars, NO prefix>
BODY:
## Description
<2-3 sentences: what needs to be done and why>

## Acceptance Criteria
<2-4 bullet checkboxes with concrete verification commands or assertions>
- [ ] Criterion: \`command to verify\`

## Done Definition
<One sentence. A human reads this and knows whether to stop iterating.>

## Scope Boundary
- DO: <specific actions in scope>
- DO NOT: <specific actions out of scope>

Rules:
- Title MUST be <=50 characters (this is a hard limit for git subject lines)
- Title MUST use imperative mood (\"fix bug\" not \"fixes bug\" or \"fixed bug\")
- Title should describe WHAT to do, not HOW
- Title must NOT have a conventional commit prefix (no fix:, feat:, etc.)
- Acceptance criteria MUST be verifiable (testable assertions, not vague \"works correctly\")
- Scope boundary should capture what's in/out of this issue
- Do NOT use markdown formatting in the title (no **, *, \`, #)
- Do NOT ask questions — make reasonable assumptions and state them in Scope Boundary"

  local generated_title=""
  local generated_body=""

  if [ -n "$claude_cmd" ]; then
    # Write prompt to temp file for stdin passing
    local prompt_file
    prompt_file=$(mktemp)
    echo "$prompt" > "$prompt_file"

    print_info "Generating structured issue from description..." >&2

    local claude_output
    claude_output=$($claude_cmd --print < "$prompt_file" 2>/dev/null) || true
    rm -f "$prompt_file"

    if [ -n "$claude_output" ]; then
      # Parse TITLE: and BODY: markers
      generated_title=$(echo "$claude_output" | sed -n 's/^TITLE: *//p' | head -1)
      # Everything after the BODY: line
      generated_body=$(echo "$claude_output" | sed -n '/^BODY:/,$p' | tail -n +2)
    fi
  fi

  # Fallback if Claude failed or unavailable: bash-only cleanup
  if [ -z "$generated_title" ]; then
    if [ -n "$claude_cmd" ]; then
      print_warning "Claude generation failed — falling back to bash cleanup" >&2
    else
      print_warning "Claude CLI not found — falling back to bash cleanup" >&2
    fi

    generated_title=$(_cleanup_title "$input_text")
    generated_body="$input_text"
  fi

  # Strip markdown from title (safety net)
  generated_title=$(echo "$generated_title" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')

  # Validate title length
  if [ ${#generated_title} -gt 50 ]; then
    local original_title="$generated_title"
    generated_title=$(_truncate_at_word_boundary "$generated_title" 50)
    print_warning "Title was truncated to 50 chars (git subject line limit)" >&2
    print_info "  Original: $original_title" >&2
    print_info "  Truncated: $generated_title" >&2
  fi

  # Display for approval (always interactive, even in --auto)
  echo "" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
  echo -e "${BLUE} Generated Issue${NC}" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
  echo "" >&2
  echo -e "Title: ${GREEN}${generated_title}${NC}" >&2
  echo "" >&2
  if [ -n "$generated_body" ]; then
    echo "$generated_body" >&2
  fi
  echo "" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

  # Approval loop
  while true; do
    read -p "Approve and create issue? (y/n/e to edit title) " -n 1 -r </dev/tty
    echo >&2

    if [[ $REPLY =~ ^[Yy]$ ]]; then
      break
    elif [[ $REPLY =~ ^[Nn]$ ]]; then
      print_info "Aborted. No issue was created." >&2
      return 1
    elif [[ $REPLY =~ ^[Ee]$ ]]; then
      echo -n "Enter new title: " >&2
      read -r generated_title </dev/tty
      # Validate edited title
      generated_title=$(echo "$generated_title" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')
      if [ ${#generated_title} -gt 50 ]; then
        generated_title=$(_truncate_at_word_boundary "$generated_title" 50)
        print_warning "Title truncated to 50 chars: $generated_title" >&2
      fi
      echo "" >&2
      echo -e "New title: ${GREEN}${generated_title}${NC}" >&2
      echo "" >&2
    fi
  done

  # Create the issue on GitHub
  print_info "Creating GitHub issue..." >&2
  local issue_url
  local _gh_exit=0
  if [ -n "$generated_body" ]; then
    issue_url=$(gh issue create --title "$generated_title" --body "$generated_body" 2>&1) || _gh_exit=$?
  else
    issue_url=$(gh issue create --title "$generated_title" --body "Created by rite from CLI description." 2>&1) || _gh_exit=$?
  fi

  if [ $_gh_exit -ne 0 ]; then
    print_error "Failed to create GitHub issue: $issue_url" >&2
    return 1
  fi

  local issue_number
  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -z "$issue_number" ]; then
    print_error "Could not extract issue number from: $issue_url" >&2
    return 1
  fi

  print_success "Created issue #${issue_number}: ${generated_title}" >&2

  # Set variables in calling scope
  ISSUE_NUMBER="$issue_number"
  ISSUE_DESC="$generated_title"
  NORMALIZED_SUBJECT="$generated_title"
  WORK_DESCRIPTION="${generated_title}

${generated_body}"
  GENERATED_ISSUE_BODY="$generated_body"

  return 0
}

# ===================================================================
# PATH B: Pre-existing GitHub issues (rite 42)
# ===================================================================
#
# Applies bash-only cleanup to the existing issue title.
# Expects: ISSUE_NUMBER, ISSUE_DESC, ISSUE_BODY to be set in calling scope.
# Sets: NORMALIZED_SUBJECT, WORK_DESCRIPTION
# Returns: 0 (always succeeds)
normalize_existing_issue() {
  local original_title="$ISSUE_DESC"

  local cleaned
  cleaned=$(_cleanup_title "$original_title")

  # Build WORK_DESCRIPTION — use cleaned title + any split remainder + body
  local full_context="$cleaned"
  if [ -n "${_TITLE_REMAINDER:-}" ]; then
    full_context="${cleaned} — ${_TITLE_REMAINDER}"
  fi

  if [ -n "${ISSUE_BODY:-}" ] && [ "$ISSUE_BODY" != "null" ]; then
    WORK_DESCRIPTION="${full_context}

${ISSUE_BODY}"
  else
    WORK_DESCRIPTION="$full_context"
  fi

  # Already normalized: ≤50, no markdown, no prefix stripped, imperative mood.
  if [ "$cleaned" = "$original_title" ] && _is_imperative_title "$cleaned"; then
    NORMALIZED_SUBJECT="$cleaned"
    return 0
  fi

  # Show what changed
  if [ "$cleaned" != "$original_title" ]; then
    print_info "Title: ${cleaned}" >&2
    if [ -n "${_TITLE_REMAINDER:-}" ]; then
      print_info "  (context moved to description)" >&2
    fi
  fi

  NORMALIZED_SUBJECT="$cleaned"
  return 0
}

# ===================================================================
# INTERNAL HELPERS
# ===================================================================

# Check if title uses imperative mood (verb-noun format).
# Rejects articles, gerunds (-ing), past tense (-ed), pronouns.
_is_imperative_title() {
  local first_word
  first_word=$(echo "$1" | awk '{print tolower($1)}')

  # Reject articles, determiners, pronouns
  case "$first_word" in
    the|a|an|this|that|these|those|it|its|we|our|my|i) return 1 ;;
  esac

  # Reject gerund (-ing) or past participle (-ed)
  case "$first_word" in
    *ing|*ed) return 1 ;;
  esac

  return 0
}

# Find a natural split point in text that fits within max_len.
# Tries structural breaks (dashes) then contextual conjunctions.
# Prints the title portion on success, returns 1 on failure.
_find_natural_split() {
  local text="$1"
  local max_len="$2"
  local lower
  lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  local pat prefix pos
  for pat in " - " " — " " – " " because " " since " " when " " so that " " which " " due to " " in order to "; do
    prefix="${lower%%${pat}*}"
    if [ "$prefix" != "$lower" ]; then
      pos=${#prefix}
      if [ "$pos" -le "$max_len" ] && [ "$pos" -ge 10 ]; then
        echo "${text:0:$pos}"
        return 0
      fi
    fi
  done

  return 1
}

# Detect conventional commit prefix from keywords in the title.
_detect_commit_prefix() {
  local text="$1"
  local prefix="feat"

  if echo "$text" | grep -iqE '(fix|bug|issue|error)'; then
    prefix="fix"
  elif echo "$text" | grep -iqE '(docs|documentation|readme)'; then
    prefix="docs"
  elif echo "$text" | grep -iqE '(test|testing|spec)'; then
    prefix="test"
  elif echo "$text" | grep -iqE '(refactor|cleanup|improve)'; then
    prefix="refactor"
  elif echo "$text" | grep -iqE '(chore|setup|config)'; then
    prefix="chore"
  fi

  echo "$prefix"
}

# Use Claude to condense a long title into ≤50 char imperative form.
# Returns 0 on success (prints condensed title), 1 on failure.
_paraphrase_title() {
  local long_title="$1"
  local claude_cmd
  claude_cmd=$(_detect_claude_cmd)
  [ -n "$claude_cmd" ] || return 1

  print_info "Condensing title..." >&2

  local result
  result=$(printf "Condense this into an imperative-mood title, maximum 50 characters. Output ONLY the condensed title — no quotes, no prefix, no explanation.\n\n%s" "$long_title" | $claude_cmd --print 2>/dev/null) || return 1

  # Validate: single line, strip formatting, strip prefix Claude might add
  result=$(echo "$result" | head -1 | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //; s/^"//; s/"$//')
  result=$(echo "$result" | sed -E 's/^(fix|feat|docs|test|refactor|chore|build|ci|perf|style)(\([^)]*\))?: //')

  if [ -n "$result" ] && [ ${#result} -le 50 ]; then
    echo "$result"
    return 0
  fi

  return 1
}

# Title cleanup: strips markdown/prefix, splits or paraphrases long titles.
# Sets _TITLE_REMAINDER with context split off or full original for paraphrased titles.
_cleanup_title() {
  local title="$1"
  _TITLE_REMAINDER=""

  # 1. Strip markdown artifacts
  local cleaned
  cleaned=$(echo "$title" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')

  # 2. Strip conventional commit prefix (prefix moves to commit time)
  cleaned=$(echo "$cleaned" | sed -E 's/^(fix|feat|docs|test|refactor|chore|build|ci|perf|style)(\([^)]*\))?: //')

  # 3. Already short enough? Done.
  if [ ${#cleaned} -le 50 ]; then
    echo "$cleaned"
    return
  fi

  # 4. Try splitting at a natural break point
  local split_title
  split_title=$(_find_natural_split "$cleaned" 50) && {
    _TITLE_REMAINDER="${cleaned:${#split_title}}"
    # Strip leading separators and whitespace from remainder
    _TITLE_REMAINDER=$(echo "$_TITLE_REMAINDER" | sed -E 's/^[[:space:]]*[-–—]+[[:space:]]*//')
    echo "$split_title"
    return
  }

  # 5. No natural split — full original goes to description
  _TITLE_REMAINDER="$cleaned"

  # 5a. Claude paraphrase: condense into imperative ≤50
  local paraphrased
  paraphrased=$(_paraphrase_title "$cleaned") && {
    echo "$paraphrased"
    return
  }

  # 5b. Last resort: truncate (Claude unavailable)
  echo "$(_truncate_at_word_boundary "$cleaned" 50)"
}
