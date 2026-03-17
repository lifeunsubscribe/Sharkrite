#!/bin/bash

# bootstrap-docs.sh - One-time bootstrap of .rite/docs/ from codebase
# Called by workflow-runner.sh when internal docs are missing or sparse.
# All output is machine-formatted reference data.

# Source configuration if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

RITE_INTERNAL_DOCS_DIR="${RITE_INTERNAL_DOCS_DIR:-${RITE_PROJECT_ROOT}/.rite/docs}"

# --- Skip helper: don't overwrite existing docs with >10 lines ---
_skip_existing() {
  local file="$1"
  if [ -f "$file" ] && [ "$(wc -l < "$file")" -gt 10 ]; then
    print_info "  $(basename "$file") already exists ($(wc -l < "$file") lines), skipping"
    return 0
  fi
  return 1
}

# --- Large codebase gate ---
FILE_COUNT=$(find . -type f \
  -not -path '*/.git/*' -not -path '*/node_modules/*' \
  -not -path '*/.rite/*' -not -path '*/vendor/*' \
  -not -path '*/__pycache__/*' 2>/dev/null | wc -l | xargs)

if [ "$FILE_COUNT" -gt 500 ]; then
  EST_TOKENS=$((FILE_COUNT * 30 + 10000))
  EST_PCT=$(( (EST_TOKENS * 100) / 500000 ))
  [ "$EST_PCT" -lt 1 ] && EST_PCT=1
  print_warning "Large codebase detected ($FILE_COUNT files)"
  print_info "Estimated: ~${EST_TOKENS} tokens (~${EST_PCT}% of a typical Pro session)"
  print_info "One-time scan to build Sharkrite's internal project knowledge."

  if [ "${WORKFLOW_MODE:-}" = "unsupervised" ]; then
    print_info "Auto mode: proceeding with bootstrap"
  else
    read -p "Proceed? (Y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
      print_info "Skipping bootstrap. Internal docs will build incrementally per-PR."
      return 0 2>/dev/null || exit 0
    fi
  fi
fi

# Check Claude CLI availability
if ! command -v claude &> /dev/null; then
  print_warning "Claude CLI not found — skipping bootstrap (internal docs will build incrementally)"
  return 0 2>/dev/null || exit 0
fi

echo ""
echo "🔍 Bootstrapping internal docs from codebase..."
echo ""

mkdir -p "${RITE_INTERNAL_DOCS_DIR}" "${RITE_INTERNAL_DOCS_DIR}/adr"

# =====================================================================
# CHANGELOG
# =====================================================================

CHANGELOG_FILE="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
if ! _skip_existing "$CHANGELOG_FILE"; then
  GIT_LOG=$(git log --oneline -50 2>/dev/null || echo "")
  if [ -n "$GIT_LOG" ]; then
    PROMPT_FILE=$(mktemp)
    cat > "$PROMPT_FILE" <<'PROMPT_EOF'
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Convert this git log into a machine-formatted changelog. Output format:

# Changelog

## YYYY-MM-DD
- type: commit message (#PR if visible) [files if inferrable]

Group by date. Types: feat, fix, refactor, docs, test, chore, change.
Infer type from conventional commit prefix or message content.

Git log:
PROMPT_EOF
    echo "$GIT_LOG" >> "$PROMPT_FILE"

    CHANGELOG_OUTPUT=$(claude --print --dangerously-skip-permissions < "$PROMPT_FILE" 2>/dev/null) || true
    rm -f "$PROMPT_FILE"

    if [ -n "$CHANGELOG_OUTPUT" ]; then
      echo "$CHANGELOG_OUTPUT" > "$CHANGELOG_FILE"
      echo "📝 .rite/docs/changelog.md ✓"
    fi
  fi
fi

# =====================================================================
# SECURITY
# =====================================================================

SECURITY_FILE="${RITE_INTERNAL_DOCS_DIR}/security.md"
if ! _skip_existing "$SECURITY_FILE"; then
  # Gather security-relevant context
  AUTH_PATTERN="${BLOCKER_AUTH_PATHS:-auth/|Auth|authentication|authorization|cognito|oauth}"
  AUTH_FILES=$(find . -type f \( -name "*.sh" -o -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) \
    2>/dev/null | grep -iE "$AUTH_PATTERN" | head -20 || echo "")

  ENV_FILES=$(find . -name ".env*" -o -name "*.env" -o -name "credentials*" -o -name "*secret*" \
    2>/dev/null | grep -v node_modules | grep -v .git | head -10 || echo "")

  BLOCKER_CONFIG=""
  if [ -f "${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/blockers.conf" ]; then
    BLOCKER_CONFIG=$(cat "${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/blockers.conf")
  fi

  PKG_AUDIT=""
  if [ -f "package.json" ]; then
    PKG_AUDIT=$(npm audit --json 2>/dev/null | head -50 || echo "")
  fi

  PROMPT_FILE=$(mktemp)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this project's security posture. Output format:

# Security Findings

## Auth Files
<file_path> — <one-line description of auth mechanism>

## Credential Handling
<pattern>: <file_paths>

## Blocker Configuration
<summary of configured blocker rules>

## Gaps
- <gap description>

Auth-related files:
${AUTH_FILES}

Environment/credential files:
${ENV_FILES}

Blocker configuration:
${BLOCKER_CONFIG}

Package audit (truncated):
${PKG_AUDIT}
PROMPT_EOF

  SECURITY_OUTPUT=$(claude --print --dangerously-skip-permissions < "$PROMPT_FILE" 2>/dev/null) || true
  rm -f "$PROMPT_FILE"

  if [ -n "$SECURITY_OUTPUT" ]; then
    echo "$SECURITY_OUTPUT" > "$SECURITY_FILE"
    echo "🔒 .rite/docs/security.md ✓"
  fi
fi

# =====================================================================
# ARCHITECTURE
# =====================================================================

ARCH_FILE="${RITE_INTERNAL_DOCS_DIR}/architecture.md"
if ! _skip_existing "$ARCH_FILE"; then
  # Gather architecture context
  DIR_TREE=$(find . -type d -maxdepth 3 \
    -not -path '*/.git*' -not -path '*/node_modules*' \
    -not -path '*/.rite*' -not -path '*/vendor*' \
    -not -path '*/__pycache__*' 2>/dev/null | sort | head -50)

  ENTRY_POINTS=$(find . -maxdepth 2 -name "main.*" -o -name "index.*" -o -name "app.*" \
    -o -name "entrypoint.*" 2>/dev/null | grep -v node_modules | grep -v .git | head -10 || echo "")

  BIN_FILES=$(find . -path "*/bin/*" -type f 2>/dev/null | head -10 || echo "")

  # Key individual files: config, settings, database, storage, schemas
  KEY_FILES=$(find . -maxdepth 4 -type f \
    \( -name "config.*" -o -name "settings.*" -o -name "database.*" \
       -o -name "seed.*" -o -name "storage*.*" -o -name "schema.*" \
       -o -name "constants.*" -o -name "env.*" \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -not -path '*/.rite/*' -not -path '*/vendor/*' \
    -not -path '*/__pycache__/*' 2>/dev/null | head -20 || echo "")

  # Key file headers (first 15 lines each) for actual defaults and structure
  KEY_FILE_HEADERS=""
  if [ -n "$KEY_FILES" ]; then
    while IFS= read -r kf; do
      [ -z "$kf" ] && continue
      KEY_FILE_HEADERS="$KEY_FILE_HEADERS\n--- $kf ---\n$(head -15 "$kf" 2>/dev/null)\n"
    done <<< "$KEY_FILES"
  fi

  # ORM/model detection: find files defining models, entities, schemas
  MODEL_FILES=$(grep -rlE \
    "(class \w+\(.*Model|class \w+\(.*Base\)|@Entity|@Table|@dataclass|schema\.Schema|Table\(|Mapped\[)" \
    --include="*.py" --include="*.ts" --include="*.js" --include="*.java" --include="*.go" \
    . 2>/dev/null | grep -v node_modules | grep -v .git | grep -v __pycache__ | head -20 || echo "")

  # Extract model class names and relationships from detected files
  MODEL_DEFINITIONS=""
  if [ -n "$MODEL_FILES" ]; then
    while IFS= read -r mf; do
      [ -z "$mf" ] && continue
      # Extract class definitions and relationship lines
      local_defs=$(grep -nE "(^class |relationship\(|ForeignKey|association_table|ManyToMany|OneToMany|BelongsTo|hasMany|references)" "$mf" 2>/dev/null | head -15 || echo "")
      if [ -n "$local_defs" ]; then
        MODEL_DEFINITIONS="$MODEL_DEFINITIONS\n--- $mf ---\n$local_defs\n"
      fi
    done <<< "$MODEL_FILES"
  fi

  CONFIG_PATTERNS=""
  if [ -f "CLAUDE.md" ]; then
    CONFIG_PATTERNS=$(head -150 CLAUDE.md)
  fi

  EXISTING_DOCS=""
  for doc in docs/**/*.md CLAUDE.md README.md; do
    if [ -f "$doc" ]; then
      EXISTING_DOCS="$EXISTING_DOCS\n--- $doc ---\n$(head -30 "$doc")\n"
    fi
  done

  # Detect stub/empty source files (< 10 lines, common indicator of unbuilt modules)
  STUB_FILES=$(find . -maxdepth 4 -type f \
    \( -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.go" -o -name "*.rs" \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' \
    -not -name "__init__.py" -not -name "*.d.ts" 2>/dev/null | \
    xargs wc -l 2>/dev/null | awk '$1 > 0 && $1 < 10 && $2 != "total"' | head -15 || echo "")

  PROMPT_FILE=$(mktemp)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Build a module map for this project. Output format:

# Architecture Reference

## Module Map
<dir_path>/ — <purpose>

## Key Files
<file_path> — <purpose, actual defaults/values from file content>

## Entry Points
<file_path> — <what it does>

## Config Variables
<VAR_NAME>=<actual_default_from_code> — <purpose>
IMPORTANT: Extract defaults from actual source code, not from documentation.
If a config file shows DATABASE_URL defaulting to sqlite:///./data/app.db, use THAT value.

## Dependencies
<from> → <to> — <relationship>

$(if [ -n "$MODEL_DEFINITIONS" ]; then cat <<'MODEL_SECTION'
## Data Model
<ModelName> — <purpose>
  → <RelatedModel> (relationship_type, FK: field_name)
Include ALL model/entity classes found. List association/join tables separately.
MODEL_SECTION
fi)

## Current State
- Built: <list components that have substantial implementation>
- Stubbed/Empty: <list files with < 10 lines of code — placeholders>
- Phase: <infer current development phase from docs/git history if possible>

Directory structure:
${DIR_TREE}

Entry points:
${ENTRY_POINTS}
${BIN_FILES}

Key files (with headers):
$(echo -e "$KEY_FILE_HEADERS")

$(if [ -n "$MODEL_DEFINITIONS" ]; then echo "Model/entity definitions:"; echo -e "$MODEL_DEFINITIONS"; fi)

$(if [ -n "$STUB_FILES" ]; then echo "Stub/empty files (< 10 lines):"; echo "$STUB_FILES"; fi)

Config/architecture context:
${CONFIG_PATTERNS}

Existing docs (headers):
$(echo -e "$EXISTING_DOCS")
PROMPT_EOF

  ARCH_OUTPUT=$(claude --print --dangerously-skip-permissions < "$PROMPT_FILE" 2>/dev/null) || true
  rm -f "$PROMPT_FILE"

  if [ -n "$ARCH_OUTPUT" ]; then
    echo "$ARCH_OUTPUT" > "$ARCH_FILE"
    echo "🏗️  .rite/docs/architecture.md ✓"
  fi
fi

# =====================================================================
# API
# =====================================================================

API_FILE="${RITE_INTERNAL_DOCS_DIR}/api.md"
if ! _skip_existing "$API_FILE"; then
  # Gather API context
  CLI_HELP=""
  if [ -f "bin/rite" ]; then
    CLI_HELP=$(grep -A2 -E "(usage|--[a-z]|getopts)" bin/rite 2>/dev/null | head -40 || echo "")
  fi

  FLAG_PARSING=""
  for script in lib/core/*.sh bin/*; do
    if [ -f "$script" ]; then
      local_flags=$(grep -nE "(getopts|--[a-z]|-[a-z]\))" "$script" 2>/dev/null | head -10 || echo "")
      if [ -n "$local_flags" ]; then
        FLAG_PARSING="$FLAG_PARSING\n--- $script ---\n$local_flags"
      fi
    fi
  done

  CONFIG_DEFAULTS=$(grep -E "^RITE_.*=.*:-" lib/utils/config.sh 2>/dev/null | head -30 || echo "")

  EXIT_CODES=""
  for script in lib/core/*.sh; do
    if [ -f "$script" ]; then
      # -B2 gives context (comment or condition) above each exit for semantic meaning
      local_exits=$(grep -B2 -nE "exit [0-9]" "$script" 2>/dev/null | head -20 || echo "")
      if [ -n "$local_exits" ]; then
        EXIT_CODES="$EXIT_CODES\n--- $script ---\n$local_exits"
      fi
    fi
  done

  PROMPT_FILE=$(mktemp)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Build an API reference. Output format:

# API Reference

## CLI Flags
| Flag | Script | Description |
|------|--------|-------------|
| --flag | script.sh | description |

## Config Variables
| Variable | Default | Description |
|----------|---------|-------------|
| VAR | value | description |

## Exit Codes
| Code | Script | Meaning | Semantic |
|------|--------|---------|----------|
| N | script.sh | meaning | success/skip/error |
IMPORTANT: The exit code context below includes 2 lines ABOVE each exit statement.
Use the surrounding condition/comment to determine semantic meaning (success vs skip vs error).
A script exiting 0 inside a "lock already held" branch is a SKIP, not success.

## Script Interfaces
| Script | Args | Description |
|--------|------|-------------|
| script.sh | <args> | description |

CLI help output:
${CLI_HELP}

Flag parsing:
$(echo -e "$FLAG_PARSING")

Config defaults:
${CONFIG_DEFAULTS}

Exit codes:
$(echo -e "$EXIT_CODES")
PROMPT_EOF

  API_OUTPUT=$(claude --print --dangerously-skip-permissions < "$PROMPT_FILE" 2>/dev/null) || true
  rm -f "$PROMPT_FILE"

  if [ -n "$API_OUTPUT" ]; then
    echo "$API_OUTPUT" > "$API_FILE"
    echo "📖 .rite/docs/api.md ✓"
  fi
fi

# =====================================================================
# ADR (suggestions only during bootstrap)
# =====================================================================

echo ""
ADR_SUGGESTIONS=$(git log --oneline -50 2>/dev/null | grep -iE "(refactor|feat|breaking|migrate|replace|switch|adopt|drop)" | head -5 || echo "")

if [ -n "$ADR_SUGGESTIONS" ]; then
  echo "💡 ADR suggestions:" >&2
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "   - \"$line\"" >&2
  done <<< "$ADR_SUGGESTIONS"
  echo "   ADRs will be auto-created per-PR at: .rite/docs/adr/" >&2
fi

# =====================================================================
# CROSS-DOCUMENT CONSISTENCY VALIDATION
# =====================================================================
# Reads all generated docs in a single prompt to find contradictions
# (e.g., architecture says PostgreSQL but api says SQLite).

_validate_cross_doc_consistency() {
  local docs_dir="$1"
  local arch_file="${docs_dir}/architecture.md"
  local api_file="${docs_dir}/api.md"
  local security_file="${docs_dir}/security.md"

  # Need at least 2 docs to cross-validate
  local doc_count=0
  [ -f "$arch_file" ] && doc_count=$((doc_count + 1))
  [ -f "$api_file" ] && doc_count=$((doc_count + 1))
  [ -f "$security_file" ] && doc_count=$((doc_count + 1))

  if [ "$doc_count" -lt 2 ]; then
    return 0
  fi

  echo "🔍 Validating cross-document consistency..."

  local arch_content=""
  [ -f "$arch_file" ] && arch_content=$(cat "$arch_file")
  local api_content=""
  [ -f "$api_file" ] && api_content=$(cat "$api_file")
  local security_content=""
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
- Do NOT flag omissions (one doc has info the other lacks — that's expected)
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
    echo "   No contradictions found"
    return 0
  fi

  # Apply corrections
  echo "$validation_output" | while IFS= read -r line; do
    if echo "$line" | grep -q "^CONTRADICTION:"; then
      echo "   ⚠ $line"
    fi
  done

  # Extract corrections and apply them via a targeted fix prompt per file
  for target_file in "$arch_file" "$api_file" "$security_file"; do
    [ -f "$target_file" ] || continue
    local target_name=$(basename "$target_file")

    # Check if any correction references this file
    if ! echo "$validation_output" | grep -q "$target_name"; then
      continue
    fi

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
        echo "   Fixed: $target_name"
      fi
    fi
  done
}

_validate_cross_doc_consistency "${RITE_INTERNAL_DOCS_DIR}"

echo ""
echo "✅ Internal docs ready at .rite/docs/"
