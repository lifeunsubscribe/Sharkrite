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

  CONFIG_PATTERNS=""
  if [ -f "CLAUDE.md" ]; then
    CONFIG_PATTERNS=$(head -100 CLAUDE.md)
  fi

  EXISTING_DOCS=""
  for doc in docs/**/*.md CLAUDE.md README.md; do
    if [ -f "$doc" ]; then
      EXISTING_DOCS="$EXISTING_DOCS\n--- $doc ---\n$(head -30 "$doc")\n"
    fi
  done

  PROMPT_FILE=$(mktemp)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Build a module map for this project. Output format:

# Architecture Reference

## Module Map
<dir_path>/ — <purpose>

## Entry Points
<file_path> — <what it does>

## Config Variables
<VAR_NAME>=<default> — <purpose>

## Dependencies
<from> → <to> — <relationship>

Directory structure:
${DIR_TREE}

Entry points:
${ENTRY_POINTS}
${BIN_FILES}

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
      local_exits=$(grep -nE "exit [0-9]" "$script" 2>/dev/null | head -5 || echo "")
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
| Code | Script | Meaning |
|------|--------|---------|
| N | script.sh | meaning |

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

echo ""
echo "✅ Internal docs ready at .rite/docs/"
