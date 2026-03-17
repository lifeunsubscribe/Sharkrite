#!/bin/bash

# assess-documentation.sh - Multi-layer documentation assessment
# Layer 1 (always): Update .rite/docs/ with machine-optimized internal docs
# Layer 2 (premium): Update user project docs IF .rite/doc-sync.md exists
#
# Usage:
#   assess-documentation.sh <PR_NUMBER> [--auto]

set -euo pipefail

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

PR_NUMBER="$1"
AUTO_MODE="${2:-}"

if [ -z "$PR_NUMBER" ]; then
  print_error "Usage: $0 <pr_number> [--auto]"
  exit 1
fi

# Check Claude CLI availability
if ! command -v claude &> /dev/null; then
  print_error "❌ Claude CLI not found"
  print_warning "Install: npm install -g @anthropic-ai/claude-cli"
  print_warning "Setup: claude setup-token"
  exit 1
fi

# Test Claude CLI
if ! echo "test" | claude --print --dangerously-skip-permissions &> /dev/null; then
  print_error "❌ Claude CLI not authenticated or not working"
  print_warning "Run: claude setup-token"
  exit 1
fi

# =====================================================================
# SHARED DATA (computed once, used by both layers)
# =====================================================================

PR_DATA=$(gh pr view "$PR_NUMBER" --json title,body,files,commits,reviews,comments)
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body // ""')
PR_DIFF=$(gh pr diff "$PR_NUMBER" | head -500)
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.files[].path' | head -30)

# =====================================================================
# LAYER 1: INTERNAL DOCS (always runs)
# =====================================================================

# Track results for one-liner summary (populated by each assess_internal_* function)
INTERNAL_UPDATED=()

mkdir -p "${RITE_INTERNAL_DOCS_DIR}" "${RITE_INTERNAL_DOCS_DIR}/adr"

# --- Internal doc helper functions ---

assess_internal_changelog() {
  local pr_number="$1"
  local pr_title="$2"
  local changed_files="$3"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# Changelog" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication: skip if PR already present
  if grep -q "#${pr_number}" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Determine change type from title
  local change_type="change"
  if echo "$pr_title" | grep -qiE "^feat"; then change_type="feat"
  elif echo "$pr_title" | grep -qiE "^fix"; then change_type="fix"
  elif echo "$pr_title" | grep -qiE "^refactor"; then change_type="refactor"
  elif echo "$pr_title" | grep -qiE "^docs"; then change_type="docs"
  elif echo "$pr_title" | grep -qiE "^test"; then change_type="test"
  elif echo "$pr_title" | grep -qiE "^chore"; then change_type="chore"
  fi

  # Build file list (compact)
  local file_list=$(echo "$changed_files" | head -5 | tr '\n' ', ' | sed 's/,$//')

  # Append entry (merge under existing date header if present)
  local today=$(date +%Y-%m-%d)
  local entry="- ${change_type}: ${pr_title} (#${pr_number}) [${file_list}]"

  if grep -q "^## $today" "$doc_file" 2>/dev/null; then
    # Insert entry after existing date header (BSD sed compatible)
    local tmp_file=$(mktemp)
    awk -v date="## $today" -v entry="$entry" '
      $0 == date { print; print entry; inserted=1; next }
      { print }
    ' "$doc_file" > "$tmp_file"
    mv "$tmp_file" "$doc_file"
  else
    {
      echo "## $today"
      echo "$entry"
      echo ""
    } >> "$doc_file"
  fi

  INTERNAL_UPDATED+=("changelog")
}

assess_internal_security() {
  local pr_number="$1"
  local pr_diff="$2"
  local changed_files="$3"
  local pr_title="$4"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/security.md"

  # Check if diff touches security-relevant files
  local auth_pattern="${BLOCKER_AUTH_PATHS:-auth/|Auth|authentication|authorization|cognito|oauth}"
  local infra_pattern="${BLOCKER_INFRASTRUCTURE_PATHS:-infrastructure/|cdk/|terraform/|cloudformation/|\.github/workflows/|\.claude/}"

  local has_security_files=false

  if echo "$changed_files" | grep -qiE "$auth_pattern" 2>/dev/null; then
    has_security_files=true
  elif echo "$changed_files" | grep -qiE "$infra_pattern" 2>/dev/null; then
    has_security_files=true
  elif echo "$changed_files" | grep -qiE "credential|token|secret|encrypt|session|password|api.?key" 2>/dev/null; then
    has_security_files=true
  elif echo "$pr_diff" | grep -qiE "credential|token|secret|encrypt|session|password|api.?key" 2>/dev/null; then
    has_security_files=true
  fi

  if [ "$has_security_files" = false ]; then
    return 0
  fi

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# Security Findings" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication
  if grep -q "#${pr_number}" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Generate structured security findings via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<SECURITY_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this PR diff for security-relevant patterns. Output in this exact format:

## PR #${pr_number} - $(date +%Y-%m-%d)
<CATEGORY>: <file_path>
- <pattern description in one line>
- <gap or concern in one line>

Categories: AUTH_CHANGE, CRED_HANDLING, INFRA_CHANGE, SESSION_MGMT, INPUT_VALIDATION, ENCRYPTION

Only include findings that exist. No empty categories.

PR Title: ${pr_title}
Changed files:
${changed_files}

Diff (truncated):
${pr_diff}
SECURITY_EOF

  local security_output
  security_output=$(claude --print --dangerously-skip-permissions < "$prompt_file" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$security_output" ]; then
    echo "" >> "$doc_file"
    echo "$security_output" >> "$doc_file"
    echo "" >> "$doc_file"
    INTERNAL_UPDATED+=("security")
  fi
}

assess_internal_architecture() {
  local pr_number="$1"
  local pr_diff="$2"
  local changed_files="$3"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/architecture.md"

  # Check if diff touches architectural files (new/removed files, config, entry points)
  local has_arch_changes=false

  # New or removed files in core source dirs
  if echo "$pr_diff" | grep -qE "^(diff --git a/|new file mode|deleted file mode)" 2>/dev/null; then
    if echo "$changed_files" | grep -qiE "\.(sh|ts|js|py|go|rs|java)$" 2>/dev/null; then
      has_arch_changes=true
    fi
  fi

  # Config variable definitions
  if echo "$pr_diff" | grep -qiE "^[\+\-].*(_CONFIG|_DIR|_PATH|_PATTERN|_MODE|export )" 2>/dev/null; then
    has_arch_changes=true
  fi

  # Entry point / dispatch changes
  if echo "$changed_files" | grep -qiE "(bin/|entrypoint|main\.|index\.|dispatch|router)" 2>/dev/null; then
    has_arch_changes=true
  fi

  if [ "$has_arch_changes" = false ]; then
    return 0
  fi

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# Architecture Reference" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication
  if grep -q "#${pr_number}" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Generate via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<ARCH_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this PR for architectural changes. Output in this exact format:

## PR #${pr_number} - $(date +%Y-%m-%d)
ADDED: <file_path> — <one-line purpose>
REMOVED: <file_path> — <was used for>
MODIFIED: <file_path> — <what changed>
CONFIG: <VAR_NAME>=<default> — <purpose>
DEPENDENCY: <from> → <to> — <relationship>

Only include categories with actual changes. No empty sections.

Changed files:
${changed_files}

Diff (truncated):
${pr_diff}
ARCH_EOF

  local arch_output
  arch_output=$(claude --print --dangerously-skip-permissions < "$prompt_file" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$arch_output" ]; then
    # Truncation safety: architecture is append-only but verify output isn't garbage
    local output_lines=$(echo "$arch_output" | wc -l | tr -d ' ')
    if [ "$output_lines" -gt 1 ]; then
      echo "" >> "$doc_file"
      echo "$arch_output" >> "$doc_file"
      echo "" >> "$doc_file"
      INTERNAL_UPDATED+=("architecture")
    fi
  fi
}

assess_internal_api() {
  local pr_number="$1"
  local pr_diff="$2"
  local changed_files="$3"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/api.md"

  # Check if diff modifies CLI flags, help text, config vars, exit codes, script interfaces
  local has_api_changes=false

  if echo "$pr_diff" | grep -qiE "(getopts|--[a-z]|usage:|exit [0-9]|print_error.*Usage)" 2>/dev/null; then
    has_api_changes=true
  elif echo "$pr_diff" | grep -qiE "^[\+\-].*RITE_" 2>/dev/null; then
    has_api_changes=true
  elif echo "$changed_files" | grep -qiE "(bin/|cli|help)" 2>/dev/null; then
    has_api_changes=true
  fi

  if [ "$has_api_changes" = false ]; then
    return 0
  fi

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# API Reference" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication
  if grep -q "#${pr_number}" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Generate via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<API_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this PR for API/CLI interface changes. Output in this exact format:

## PR #${pr_number} - $(date +%Y-%m-%d)
FLAG: --flag-name — <description> (added|changed|removed)
CONFIG: VAR_NAME=default — <description> (added|changed|removed)
EXIT_CODE: N — <meaning> (added|changed)
INTERFACE: script.sh <args> — <change description>

Only include categories with actual changes. No empty sections.

Changed files:
${changed_files}

Diff (truncated):
${pr_diff}
API_EOF

  local api_output
  api_output=$(claude --print --dangerously-skip-permissions < "$prompt_file" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$api_output" ]; then
    local output_lines=$(echo "$api_output" | wc -l | tr -d ' ')
    if [ "$output_lines" -gt 1 ]; then
      echo "" >> "$doc_file"
      echo "$api_output" >> "$doc_file"
      echo "" >> "$doc_file"
      INTERNAL_UPDATED+=("api")
    fi
  fi
}

assess_internal_adr() {
  local pr_number="$1"
  local pr_diff="$2"
  local pr_body="$3"
  local pr_title="$4"
  local adr_dir="${RITE_INTERNAL_DOCS_DIR}/adr"

  # Check if diff introduces a pattern change (new category, rule type, phase, approach substitution)
  local has_pattern_change=false

  # New phases, categories, rule types
  if echo "$pr_diff" | grep -qiE "^[\+].*(phase_|_CATEGORY|_RULE|_TYPE|_PATTERN).*=" 2>/dev/null; then
    has_pattern_change=true
  fi

  # Significant structural additions (new functions, new case arms)
  if echo "$pr_diff" | grep -cE "^\+.*(^[a-z_]+\(\)|case .* in)" 2>/dev/null | grep -qvE "^0$"; then
    has_pattern_change=true
  fi

  # PR body explicitly mentions decision/tradeoff/alternative
  if echo "$pr_body" | grep -qiE "(decision|tradeoff|trade-off|alternative|approach|instead of|replaced)" 2>/dev/null; then
    has_pattern_change=true
  fi

  if [ "$has_pattern_change" = false ]; then
    return 0
  fi

  # Scan existing ADRs for highest number
  local highest=0
  for adr_file in "$adr_dir"/*.md; do
    if [ -f "$adr_file" ]; then
      local num=$(basename "$adr_file" | grep -oE "^[0-9]+" || echo "0")
      if [ "$num" -gt "$highest" ]; then
        highest="$num"
      fi
    fi
  done
  local next_num=$((highest + 1))
  local next_num_padded=$(printf "%03d" "$next_num")

  # Deduplication: check if ADR already exists for this PR
  if grep -rl "PR: #${pr_number}" "$adr_dir" 2>/dev/null | head -1 | grep -q .; then
    return 0
  fi

  # Build compact file list for the Files: metadata line
  local changed_files_list=$(echo "$CHANGED_FILES" | head -10 | tr '\n' ', ' | sed 's/,$//')

  # Generate ADR via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<ADR_EOF
Output ONLY a single ADR document in this exact format. No extra text before or after.

# ADR-${next_num_padded}: <Brief Title>

**Date:** $(date +%Y-%m-%d)
**PR:** #${pr_number}
**Files:** ${changed_files_list}
**Context:** <1-2 lines from PR body and diff explaining why this change was needed>
**Decision:** <1-2 lines describing what was changed>
**Tradeoffs:** <1-2 lines on what was gained vs lost>

PR Title: ${pr_title}
PR Body:
${pr_body}

Diff (truncated):
${pr_diff}
ADR_EOF

  local adr_output
  adr_output=$(claude --print --dangerously-skip-permissions < "$prompt_file" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$adr_output" ]; then
    # Extract brief title for filename
    local brief_title=$(echo "$adr_output" | head -1 | sed 's/^# ADR-[0-9]*: //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40)
    if [ -z "$brief_title" ]; then
      brief_title="pr-${pr_number}"
    fi

    local adr_file="${adr_dir}/${next_num_padded}-${brief_title}.md"
    echo "$adr_output" > "$adr_file"
    INTERNAL_UPDATED+=("ADR-${next_num_padded}")
  fi
}

# --- Run internal doc assessments ---

assess_internal_changelog "$PR_NUMBER" "$PR_TITLE" "$CHANGED_FILES"
assess_internal_security "$PR_NUMBER" "$PR_DIFF" "$CHANGED_FILES" "$PR_TITLE"
assess_internal_architecture "$PR_NUMBER" "$PR_DIFF" "$CHANGED_FILES"
assess_internal_api "$PR_NUMBER" "$PR_DIFF" "$CHANGED_FILES"
assess_internal_adr "$PR_NUMBER" "$PR_DIFF" "$PR_BODY" "$PR_TITLE"

# --- Reconciliation pass: fold PR deltas into baseline ---
# Triggered when a doc accumulates 3+ PR sections. Merges append-only deltas
# back into the baseline so stale top-level statements get corrected.

reconcile_internal_doc() {
  local doc_file="$1"
  local doc_name="$2"

  [ -f "$doc_file" ] || return 0

  # Count PR delta sections (## PR #N headers)
  local pr_section_count
  pr_section_count=$(grep -c "^## PR #" "$doc_file" 2>/dev/null || true)

  # Only reconcile when 3+ PR sections have accumulated
  if [ "$pr_section_count" -lt 3 ]; then
    return 0
  fi

  local current_content
  current_content=$(cat "$doc_file")
  local current_lines
  current_lines=$(echo "$current_content" | wc -l | tr -d ' ')

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" <<RECONCILE_EOF
Output ONLY the reconciled document. No explanations before or after.

This ${doc_name} document has a baseline section followed by incremental PR delta sections.
The PR deltas contain newer, more accurate information that may contradict the baseline.

Your task: merge ALL PR delta information INTO the baseline sections, then REMOVE the PR delta
sections. The result should be a single cohesive document with no "## PR #N" sections remaining.

Rules:
- When a PR delta contradicts the baseline, the PR delta is correct (it's newer)
- Preserve all information from PR deltas — fold it into the appropriate baseline section
- If the baseline says something like "No X found" but a PR delta documents X, UPDATE the baseline
- Keep the same top-level structure and format as the baseline
- Do NOT add prose, explanations, or summaries — maintain machine-formatted reference style
- Do NOT lose any information from either baseline or deltas

Current document:
${current_content}
RECONCILE_EOF

  local reconciled_output
  reconciled_output=$(claude --print --dangerously-skip-permissions < "$prompt_file" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -z "$reconciled_output" ]; then
    return 0
  fi

  # Truncation safety: reconciled doc should be at least 60% of original
  local new_lines
  new_lines=$(echo "$reconciled_output" | wc -l | tr -d ' ')
  local min_lines=$((current_lines * 60 / 100))

  if [ "$new_lines" -lt "$min_lines" ]; then
    print_warning "  Reconciliation of $doc_name skipped (output too short: ${new_lines} vs ${current_lines} lines)"
    return 0
  fi

  # Verify PR sections were actually merged (no ## PR # headers should remain)
  local remaining_pr_sections
  remaining_pr_sections=$(echo "$reconciled_output" | grep -c "^## PR #" 2>/dev/null || true)
  if [ "$remaining_pr_sections" -gt 0 ]; then
    print_warning "  Reconciliation of $doc_name skipped (PR sections not merged)"
    return 0
  fi

  echo "$reconciled_output" > "$doc_file"
  INTERNAL_UPDATED+=("${doc_name}(reconciled)")
}

# Run reconciliation on docs that accumulate PR deltas
reconcile_internal_doc "${RITE_INTERNAL_DOCS_DIR}/security.md" "security"
reconcile_internal_doc "${RITE_INTERNAL_DOCS_DIR}/architecture.md" "architecture"
reconcile_internal_doc "${RITE_INTERNAL_DOCS_DIR}/api.md" "api"

# --- Cross-document consistency validation ---
# Same logic as bootstrap-docs.sh but runs during assessment when a reconciliation
# just happened (docs were rewritten, good time to catch cross-doc drift).

_validate_cross_doc_consistency() {
  local docs_dir="$1"
  local arch_file="${docs_dir}/architecture.md"
  local api_file="${docs_dir}/api.md"
  local security_file="${docs_dir}/security.md"

  # Need at least 2 docs
  local doc_count=0
  [ -f "$arch_file" ] && doc_count=$((doc_count + 1))
  [ -f "$api_file" ] && doc_count=$((doc_count + 1))
  [ -f "$security_file" ] && doc_count=$((doc_count + 1))
  [ "$doc_count" -lt 2 ] && return 0

  local arch_content="" api_content="" security_content=""
  [ -f "$arch_file" ] && arch_content=$(cat "$arch_file")
  [ -f "$api_file" ] && api_content=$(cat "$api_file")
  [ -f "$security_file" ] && security_content=$(cat "$security_file")

  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<VALIDATE_EOF
You are validating consistency across multiple generated documentation files.
Find CONTRADICTIONS between documents — places where two docs state different facts
about the same thing (e.g., different default values, conflicting file lists, one doc
says a feature exists while another says it doesn't).

Output format — ONLY output contradictions found. If none, output exactly: NO_CONTRADICTIONS

For each contradiction:
CONTRADICTION: <brief description>
FILE1: <filename> LINE: "<the contradicting text>"
FILE2: <filename> LINE: "<the contradicting text>"
CORRECTION: <which file is likely correct and what the fix is>

Rules:
- Only flag actual contradictions (same fact, different values)
- Do NOT flag omissions (one doc has info the other lacks)
- Do NOT flag stylistic differences
- Focus on: default values, file paths, feature existence claims, configuration

--- architecture.md ---
${arch_content}

--- api.md ---
${api_content}

--- security.md ---
${security_content}
VALIDATE_EOF

  local validation_output
  validation_output=$(claude --print --dangerously-skip-permissions < "$prompt_file" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -z "$validation_output" ] || echo "$validation_output" | grep -q "^NO_CONTRADICTIONS"; then
    return 0
  fi

  # Apply corrections per file
  for target_file in "$arch_file" "$api_file" "$security_file"; do
    [ -f "$target_file" ] || continue
    local target_name=$(basename "$target_file")
    echo "$validation_output" | grep -q "$target_name" || continue

    local current_content=$(cat "$target_file")
    local fix_prompt_file=$(mktemp)
    cat > "$fix_prompt_file" <<FIX_EOF
Apply ONLY the corrections listed below to this document. Change nothing else.
Output the COMPLETE corrected file.

Corrections to apply:
${validation_output}

Current ${target_name}:
${current_content}
FIX_EOF

    local fixed_output
    fixed_output=$(claude --print --dangerously-skip-permissions < "$fix_prompt_file" 2>/dev/null) || true
    rm -f "$fix_prompt_file"

    if [ -n "$fixed_output" ]; then
      local orig_lines=$(echo "$current_content" | wc -l | tr -d ' ')
      local fixed_lines=$(echo "$fixed_output" | wc -l | tr -d ' ')
      local min_lines=$((orig_lines * 80 / 100))
      if [ "$fixed_lines" -ge "$min_lines" ]; then
        echo "$fixed_output" > "$target_file"
        INTERNAL_UPDATED+=("${target_name}(consistency-fix)")
      fi
    fi
  done
}

# Only run cross-doc validation when a reconciliation actually happened
# (indicated by "(reconciled)" in INTERNAL_UPDATED)
RECONCILED=false
for item in "${INTERNAL_UPDATED[@]}"; do
  if echo "$item" | grep -q "reconciled"; then
    RECONCILED=true
    break
  fi
done

if [ "$RECONCILED" = true ]; then
  _validate_cross_doc_consistency "${RITE_INTERNAL_DOCS_DIR}"
fi

# Commit internal doc changes if any
if [ -n "$(git diff --name-only .rite/docs/ 2>/dev/null)" ] || [ -n "$(git ls-files --others --exclude-standard .rite/docs/ 2>/dev/null)" ]; then
  git add .rite/docs/
  git commit -m "docs(rite): update internal docs for PR #$PR_NUMBER" 2>/dev/null || true
fi

# =====================================================================
# COMBINED OUTPUT HEADER
# =====================================================================

print_header "📚 Documentation"

# Internal docs one-liner summary
if [ ${#INTERNAL_UPDATED[@]} -gt 0 ]; then
  INTERNAL_SUMMARY=$(printf '%s ✓  ' "${INTERNAL_UPDATED[@]}")
  echo -e "${GREEN}    Internal: ${INTERNAL_SUMMARY% }${NC}"
else
  print_info "  Internal: up to date"
fi

# =====================================================================
# LAYER 2: USER PROJECT DOCS (only if doc-sync.md exists)
# =====================================================================

DOC_SYNC_FILE="${RITE_PROJECT_ROOT}/.rite/doc-sync.md"

if [ ! -f "$DOC_SYNC_FILE" ]; then
  echo ""
  exit 0
fi

# Read custom sync instructions
DOC_SYNC_INSTRUCTIONS=$(cat "$DOC_SYNC_FILE")

# --- Gather context (quiet — no output) ---

# Look for Sharkrite review in formal reviews first, then comments
SHARKRITE_REVIEW=$(echo "$PR_DATA" | jq -r '[.reviews[] | select(.body | contains("sharkrite-local-review") or contains("sharkrite-review-data"))] | .[-1] | .body // ""' 2>/dev/null)

if [ -z "$SHARKRITE_REVIEW" ] || [ "$SHARKRITE_REVIEW" = "null" ]; then
  SHARKRITE_REVIEW=$(echo "$PR_DATA" | jq -r '[.comments[] | select(.body | contains("sharkrite-local-review") or contains("sharkrite-review-data"))] | .[-1] | .body // ""' 2>/dev/null)
fi

# Extract documentation-related items from review
DOC_ITEMS_FROM_REVIEW=""
REVIEW_HAS_DOC_ITEMS=false

if [ -n "$SHARKRITE_REVIEW" ] && [ "$SHARKRITE_REVIEW" != "null" ]; then
  DOC_ITEMS_FROM_REVIEW=$(echo "$SHARKRITE_REVIEW" | grep -iE "(documentation|docs/|README|CLAUDE\.md|update.*doc|missing.*doc|add.*doc)" | head -20 || echo "")
  if [ -n "$DOC_ITEMS_FROM_REVIEW" ]; then
    REVIEW_HAS_DOC_ITEMS=true
  fi
fi

# Get changed files (excluding docs/)
CHANGED_FILES_NO_DOCS=$(echo "$PR_DATA" | jq -r '.files[].path' | grep -v '^docs/' | head -20 || true)

# Get commit messages for context
COMMIT_MESSAGES=$(echo "$PR_DATA" | jq -r '.commits[].messageHeadline' | head -10)

# Get current documentation structure
DOC_FILES=$(find docs/ -name "*.md" 2>/dev/null | sort || echo "")

# Get CLAUDE.md sections if it exists
CLAUDE_MD_SECTIONS=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_MD_SECTIONS=$(grep "^##" CLAUDE.md | head -30 || true)
fi

# Get project README sections if available (configurable per project)
README_SECTIONS=""
if [ -n "${RITE_SCRIPTS_README:-}" ] && [ -f "$RITE_SCRIPTS_README" ]; then
  README_SECTIONS=$(grep "^##" "$RITE_SCRIPTS_README" | head -20 || true)
elif [ -f "README.md" ]; then
  README_SECTIONS=$(grep "^##" README.md | head -20 || true)
fi

# Get table of contents from each major doc to understand coverage
ARCHITECTURE_DOCS=""
for doc in docs/architecture/*.md; do
  if [ -f "$doc" ]; then
    ARCHITECTURE_DOCS="$ARCHITECTURE_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

PROJECT_DOCS=""
for doc in docs/project/*.md; do
  if [ -f "$doc" ]; then
    PROJECT_DOCS="$PROJECT_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

WORKFLOW_DOCS=""
for doc in docs/workflows/*.md; do
  if [ -f "$doc" ]; then
    WORKFLOW_DOCS="$WORKFLOW_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

SECURITY_DOCS=""
for doc in docs/security/*.md; do
  if [ -f "$doc" ]; then
    SECURITY_DOCS="$SECURITY_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

DEVELOPMENT_DOCS=""
for doc in docs/development/*.md; do
  if [ -f "$doc" ]; then
    DEVELOPMENT_DOCS="$DEVELOPMENT_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

# --- Assessment ---

# Build assessment prompt - include review context if available
REVIEW_CONTEXT_SECTION=""
if [ "$REVIEW_HAS_DOC_ITEMS" = true ]; then
  REVIEW_CONTEXT_SECTION="
**Documentation Items from Sharkrite Review:**
The code review already identified these documentation-related items. Use these as your primary guide:
\`\`\`
$DOC_ITEMS_FROM_REVIEW
\`\`\`

Focus on addressing the specific items mentioned in the review.
"
fi

# Pre-compute doc structure (avoid nested $() inside heredoc)
CLAUDE_MD_INLINE=$(echo "$CLAUDE_MD_SECTIONS" | head -10 | tr '\n' ';')
README_INLINE=""
if [ -n "$README_SECTIONS" ]; then
  README_INLINE="- README.md (project overview): $(echo "$README_SECTIONS" | head -10 | tr '\n' ';')"
fi

# Build assessment prompt in temp file (heredoc inside $() is fragile —
# PR body content can contain shell metacharacters that break parsing)
ASSESS_PROMPT_FILE=$(mktemp)
cat > "$ASSESS_PROMPT_FILE" <<ASSESS_PROMPT_EOF
You are reviewing a pull request to assess if documentation needs updating.

**Custom Instructions:**
$DOC_SYNC_INSTRUCTIONS

**PR Title:** $PR_TITLE

**PR Description:**
$PR_BODY
$REVIEW_CONTEXT_SECTION
**Changed Files (excluding docs/):**
$CHANGED_FILES_NO_DOCS

**Recent Commits:**
$COMMIT_MESSAGES

**Existing Documentation Structure:**

Root-level docs:
- CLAUDE.md (main architecture guide): $CLAUDE_MD_INLINE
$README_INLINE

docs/architecture/ (system design, infrastructure, database):
$(echo -e "$ARCHITECTURE_DOCS")

docs/project/ (business requirements, roadmap, pricing):
$(echo -e "$PROJECT_DOCS")

docs/workflows/ (CI/CD, automation, GitHub Actions):
$(echo -e "$WORKFLOW_DOCS")

docs/security/ (security patterns, vulnerabilities):
$(echo -e "$SECURITY_DOCS")

docs/development/ (dev guides, testing, setup):
$(echo -e "$DEVELOPMENT_DOCS")

**Your Task:**
Assess whether ANY documentation needs to be updated based on these code changes.
Use the Custom Instructions above to determine which docs to check and what rules to follow.

**Response Format:**
If documentation updates are needed, respond with:
NEEDS_UPDATE: <file1.md>, <file2.md>, <file3.md>
REASON: <Brief explanation of what needs updating>

If no documentation updates needed, respond with:
NO_UPDATE_NEEDED
REASON: <Brief explanation>

**Be strict:** Architectural changes, new patterns, new scripts, infrastructure changes ALWAYS need documentation.

**Examples of what doesn't need docs:**
- Bug fixes to existing code (no pattern change)
- Updating existing tests (no new testing strategy)
- Refactoring without behavior change
- Minor version bumps
- Comment improvements
ASSESS_PROMPT_EOF

echo "    Project docs: analyzing..."

# Run assessment
ASSESSMENT_OUTPUT=$(claude --print --dangerously-skip-permissions < "$ASSESS_PROMPT_FILE" 2>&1)
rm -f "$ASSESS_PROMPT_FILE"

# --- Apply or report ---

if echo "$ASSESSMENT_OUTPUT" | grep -q "^NEEDS_UPDATE"; then
  DOCS_TO_UPDATE=$(echo "$ASSESSMENT_OUTPUT" | grep "^NEEDS_UPDATE:" | sed 's/NEEDS_UPDATE: //')
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //')

  echo "    Project docs: $DOCS_TO_UPDATE"
  echo "    Reason: $REASON"

  # In supervised mode, confirm before applying
  APPLY_UPDATES=true
  if [ "$AUTO_MODE" != "--auto" ]; then
    echo ""
    read -p "Apply documentation updates? (Y/n): " APPLY_DOCS
    if [[ "$APPLY_DOCS" =~ ^[Nn]$ ]]; then
      APPLY_UPDATES=false
      read -p "Continue with merge without doc updates? (y/N): " CONTINUE
      if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        print_info "Merge cancelled - update documentation first"
        exit 2
      fi
    fi
  fi

  if [ "$APPLY_UPDATES" = true ]; then
    IFS=',' read -ra FILES_ARRAY <<< "$DOCS_TO_UPDATE"
    UPDATED_FILES=()
    SKIPPED_FILES=()

    for doc_file in "${FILES_ARRAY[@]}"; do
      doc_file=$(echo "$doc_file" | xargs)  # trim whitespace

      if [ ! -f "$doc_file" ]; then
        SKIPPED_FILES+=("$doc_file (not found)")
        continue
      fi

      CURRENT_CONTENT=$(cat "$doc_file")

      UPDATE_PROMPT_FILE=$(mktemp)
      cat > "$UPDATE_PROMPT_FILE" <<UPDATE_PROMPT_EOF
You are updating documentation to reflect code changes from a PR.

**Documentation Update Rule:**
- If pertinent topic exists: expand section as necessary with new information
- If topic doesn't exist: add new section in appropriate location
- Keep updates minimal and focused on the actual changes
- Consider PR scope - don't over-document minor changes
- Match existing documentation style and format

**PR Context:**
- PR #$PR_NUMBER: $PR_TITLE
- Reason for doc update: $REASON

**PR Changes (diff):**
\`\`\`
$PR_DIFF
\`\`\`

**Current Documentation Content:**
\`\`\`markdown
$CURRENT_CONTENT
\`\`\`

**Your Task:**
Update this documentation file to reflect the PR changes. Output the COMPLETE updated file.

**Guidelines:**
- Maintain all existing content unless it contradicts new changes
- Add new sections only if substantive new functionality was added
- Expand existing sections if the topic is already covered
- Use consistent markdown formatting
- Keep the same structure and organization
- Update timestamps if present (format: YYYY-MM-DD)

Output ONLY the complete updated markdown file, nothing else.
UPDATE_PROMPT_EOF

      # Retry loop for transient empty Claude CLI responses (exit 0 + empty stdout).
      # Same pattern as local-review.sh: max 2 attempts, 3s delay.
      MAX_DOC_ATTEMPTS=2
      DOC_ATTEMPT=0
      CLAUDE_EXIT=0
      UPDATED_CONTENT=""
      while [ $DOC_ATTEMPT -lt $MAX_DOC_ATTEMPTS ] && [ -z "$UPDATED_CONTENT" ]; do
        DOC_ATTEMPT=$((DOC_ATTEMPT + 1))
        CLAUDE_EXIT=0
        UPDATED_CONTENT=$(claude --print --dangerously-skip-permissions < "$UPDATE_PROMPT_FILE" 2>&1) || CLAUDE_EXIT=$?
        if [ $CLAUDE_EXIT -eq 0 ] && [ -z "$UPDATED_CONTENT" ] && [ $DOC_ATTEMPT -lt $MAX_DOC_ATTEMPTS ]; then
          print_warning "Claude returned empty doc update (attempt $DOC_ATTEMPT/$MAX_DOC_ATTEMPTS) — retrying in 3s..."
          sleep 3
        fi
      done
      rm -f "$UPDATE_PROMPT_FILE"

      if [ $CLAUDE_EXIT -eq 0 ] && [ -n "$UPDATED_CONTENT" ]; then
        # Verify update looks reasonable (not truncated)
        ORIGINAL_SIZE=$(echo "$CURRENT_CONTENT" | wc -l)
        NEW_SIZE=$(echo "$UPDATED_CONTENT" | wc -l)
        MIN_SIZE=$((ORIGINAL_SIZE * 80 / 100))

        if [ "$NEW_SIZE" -lt "$MIN_SIZE" ]; then
          SKIPPED_FILES+=("$doc_file (truncated output)")
          continue
        fi

        # Backup original
        cp "$doc_file" "${doc_file}.backup-$(date +%s)"

        # Apply update
        echo "$UPDATED_CONTENT" > "$doc_file"
        UPDATED_FILES+=("$doc_file")
      else
        SKIPPED_FILES+=("$doc_file (generation failed)")
      fi
    done

    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
      # Git add and commit
      git add "${UPDATED_FILES[@]}"

      COMMIT_MSG="docs: update documentation for PR #$PR_NUMBER

Auto-updated by doc assessment:
- Files: ${UPDATED_FILES[*]}
- Reason: $REASON

Related: #$PR_NUMBER"

      if git commit -m "$COMMIT_MSG" 2>/dev/null; then
        if git push 2>/dev/null; then
          echo -e "${GREEN}    Project docs: updated ${#UPDATED_FILES[@]} file(s) and pushed${NC}"
        else
          echo "    Project docs: updated ${#UPDATED_FILES[@]} file(s) (push failed — local only)"
        fi
      else
        echo "    Project docs: no changes to commit"
      fi

      # Send Slack notification
      if [ -n "${SLACK_WEBHOOK:-}" ]; then
        SLACK_MESSAGE=$(cat <<EOF
{
  "text": "📚 *Documentation Auto-Updated*",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*PR #$PR_NUMBER*: $PR_TITLE\\n\\n*Files updated:* \\\`${UPDATED_FILES[*]}\\\`\\n\\n*Reason:* $REASON\\n\\nDocumentation committed and merge proceeding."
      }
    }
  ]
}
EOF
)
        curl -X POST "$SLACK_WEBHOOK" \
          -H "Content-Type: application/json" \
          -d "$SLACK_MESSAGE" \
          --silent --output /dev/null
      fi
    else
      echo "    Project docs: 0 files updated"
    fi

    if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
      for f in "${SKIPPED_FILES[@]}"; do
        print_warning "  Skipped: $f"
      done
    fi
  fi
else
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //' || echo "Documentation is current")
  echo -e "${GREEN}    Project docs: up to date ($REASON)${NC}"
fi

echo ""
exit 0
