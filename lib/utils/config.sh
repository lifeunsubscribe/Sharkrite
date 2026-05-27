#!/bin/bash
# lib/utils/config.sh - Sharkrite configuration loader
# Sources: defaults → global config → project config → env vars
#
# Priority (highest wins):
#   1. Environment variables (RITE_*)
#   2. Project config ($REPO/.rite/config)
#   3. Global config (~/.config/rite/config or ~/.riterc)
#   4. Defaults (defined here)

set -euo pipefail

# =============================================================================
# HELPER: Safe config file sourcing with validation
# =============================================================================

# parse_rite_config - Strict KEY=VALUE parser for config files
# Reads config files WITHOUT executing them as shell scripts
# Only accepts lines matching: ^[A-Z_][A-Z0-9_]*=...
# Strips outer quotes from values, exports variables
# Security: No eval, no command substitution, no code execution
#
# Accepted:  KEY=value, KEY="value with spaces", KEY='value'
# Rejected:  lowercase keys, shell commands, $(subst), `backticks`, semicolons
parse_rite_config() {
  local config_file="$1"

  # Skip if file doesn't exist
  [ -f "$config_file" ] || return 0

  local line key value

  # Read line by line (preserving empty lines for || condition)
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Only process lines matching valid KEY=VALUE pattern
    # Must start with uppercase letter or underscore
    if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
      # Extract key (everything before first =)
      key="${line%%=*}"
      # Extract value (everything after first =)
      value="${line#*=}"

      # Strip outer quotes from value (single or double)
      # Preserves quotes/special chars inside the outer quotes
      if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      # Export the variable (no eval - literal string assignment)
      export "$key=$value"
    fi
    # Silently ignore invalid lines (defense in depth)
  done < "$config_file"
}

# safe_source - Still used for trusted library files (lib/utils/*.sh, lib/core/*.sh)
# DO NOT use for config files (.rite/config, .riterc, blockers.conf)
safe_source() {
  local config_file="$1"
  if [ -f "$config_file" ]; then
    # Syntax check before sourcing
    if ! bash -n "$config_file" 2>/dev/null; then
      echo "❌ Syntax error in config file: $config_file" >&2
      echo "   Run 'bash -n $config_file' to see the error" >&2
      exit 1
    fi
    source "$config_file"
  fi
}

# =============================================================================
# STEP 1: Detect Project Root (like git does)
# =============================================================================

detect_project_root() {
  if git rev-parse --show-toplevel 2>/dev/null; then
    return 0
  else
    echo ""
    return 0
  fi
}

# Only detect if not already set (caller may override)
if [ -z "${RITE_PROJECT_ROOT:-}" ]; then
  RITE_PROJECT_ROOT="$(detect_project_root)"
fi

if [ -z "$RITE_PROJECT_ROOT" ]; then
  echo "❌ Not inside a git repository. Run rite from within a project." >&2
  exit 1
fi

RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-$(basename "$RITE_PROJECT_ROOT")}"

# =============================================================================
# STEP 2: Set Defaults
# =============================================================================

# Installation paths (RITE_INSTALL_DIR should be set by bin/rite before sourcing)
RITE_INSTALL_DIR="${RITE_INSTALL_DIR:-$HOME/.rite}"
RITE_LIB_DIR="${RITE_LIB_DIR:-$RITE_INSTALL_DIR/lib}"

# Project data directory (per-repo, inside the repo)
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"

# Worktrees (global, organized by project)
RITE_WORKTREE_BASE="${RITE_WORKTREE_BASE:-$HOME/Dev/rite-wt}"
# Abbreviate project name to initials: clearance-screener → cs, sharkrite → sh
_project_abbrev=$(echo "$RITE_PROJECT_NAME" | sed 's/\([a-z]\)[a-z]*/\1/g; s/-//g')
# Single-char abbreviations are ambiguous — use first 2 chars of single-word names
[ ${#_project_abbrev} -le 1 ] && _project_abbrev="${RITE_PROJECT_NAME:0:2}"
RITE_WORKTREE_DIR="${RITE_WORKTREE_DIR:-$RITE_WORKTREE_BASE/${_project_abbrev}-wt}"

# Session limits
RITE_MAX_ISSUES_PER_SESSION="${RITE_MAX_ISSUES_PER_SESSION:-8}"
RITE_MAX_SESSION_HOURS="${RITE_MAX_SESSION_HOURS:-4}"
RITE_MAX_RETRIES="${RITE_MAX_RETRIES:-3}"
RITE_ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-120}"
RITE_STALE_BRANCH_THRESHOLD="${RITE_STALE_BRANCH_THRESHOLD:-10}"

# Workflow mode
WORKFLOW_MODE="${WORKFLOW_MODE:-supervised}"

# Notifications (opt-in per project — global env vars like SLACK_WEBHOOK are ignored
# unless RITE_NOTIFICATIONS is explicitly set to "true")
RITE_NOTIFICATIONS="${RITE_NOTIFICATIONS:-false}"
RITE_AWS_PROFILE="${RITE_AWS_PROFILE:-default}"
RITE_SNS_TOPIC_ARN="${RITE_SNS_TOPIC_ARN:-}"
RITE_EMAIL_FROM="${RITE_EMAIL_FROM:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_NOTIFICATION_ADDRESS="${EMAIL_NOTIFICATION_ADDRESS:-}"

# If notifications are not enabled, clear all notification channels so nothing fires
if [ "$RITE_NOTIFICATIONS" != "true" ]; then
  SLACK_WEBHOOK=""
  EMAIL_NOTIFICATION_ADDRESS=""
  RITE_SNS_TOPIC_ARN=""
fi

# Internal docs directory
RITE_INTERNAL_DOCS_DIR="${RITE_INTERNAL_DOCS_DIR:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/docs}"

# Scratchpad
SCRATCHPAD_FILE="${SCRATCHPAD_FILE:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md}"

# Lock directory for per-issue locking (prevents concurrent rite invocations on same issue)
RITE_LOCK_DIR="${RITE_LOCK_DIR:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/locks}"

# Session state
SESSION_STATE_FILE="${SESSION_STATE_FILE:-/tmp/rite-session-state-${RITE_PROJECT_NAME}.json}"

# Sharkrite timeout (seconds, default 2 hours)
RITE_CLAUDE_TIMEOUT="${RITE_CLAUDE_TIMEOUT:-7200}"

# Claude model for development sessions (alias without date = always latest snapshot)
RITE_CLAUDE_MODEL="${RITE_CLAUDE_MODEL:-claude-sonnet-4-5}"

# Model for reviews and assessments — opus for quality (must match for consistency)
RITE_REVIEW_MODEL="${RITE_REVIEW_MODEL:-claude-opus-4-5}"

# Provider selection (per-phase, all default to claude for backward compat)
# Available providers: claude, gemini
RITE_DEV_PROVIDER="${RITE_DEV_PROVIDER:-claude}"         # Agentic dev/fix sessions
RITE_REVIEW_PROVIDER="${RITE_REVIEW_PROVIDER:-claude}"    # Reviews, assessments, planning
RITE_UTILITY_PROVIDER="${RITE_UTILITY_PROVIDER:-claude}"  # Classify, normalize, health

# Gemini models (only used when a RITE_*_PROVIDER is set to "gemini")
RITE_GEMINI_DEV_MODEL="${RITE_GEMINI_DEV_MODEL:-gemini-2.5-pro}"
RITE_GEMINI_REVIEW_MODEL="${RITE_GEMINI_REVIEW_MODEL:-gemini-2.5-pro}"

# Plan command: default architectural doc(s) to reference (space-separated, project-relative)
RITE_PLAN_DOCS="${RITE_PLAN_DOCS:-}"
RITE_PLAN_MAX_ESTIMATE="${RITE_PLAN_MAX_ESTIMATE:-2hr}"

# Dry-run mode
RITE_DRY_RUN="${RITE_DRY_RUN:-false}"

# AWS credential checks are auto-detected via detect_aws_project() in blocker-rules.sh

# Test gate: run tests before commit in auto mode (set to "true" to skip for slow suites)
RITE_SKIP_TESTS="${RITE_SKIP_TESTS:-false}"

# Custom test command (auto-detected from project structure if unset)
RITE_TEST_CMD="${RITE_TEST_CMD:-}"

# =============================================================================
# STEP 3: Load Global Config (~/.config/rite/config)
# =============================================================================

RITE_GLOBAL_CONFIG="${RITE_GLOBAL_CONFIG:-$HOME/.config/rite/config}"
parse_rite_config "$RITE_GLOBAL_CONFIG"

# Also check ~/.riterc for convenience
parse_rite_config "$HOME/.riterc"

# =============================================================================
# STEP 4: Load Project Config ($REPO/.rite/config)
# =============================================================================

RITE_PROJECT_CONFIG="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/config"
parse_rite_config "$RITE_PROJECT_CONFIG"

# =============================================================================
# STEP 5: Load Blocker Rules (project-specific or defaults)
# =============================================================================

RITE_BLOCKERS_CONFIG="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/blockers.conf"
parse_rite_config "$RITE_BLOCKERS_CONFIG"

# Blocker pattern defaults (if not set by project config)
BLOCKER_INFRASTRUCTURE_PATHS="${BLOCKER_INFRASTRUCTURE_PATHS:-infrastructure/|cdk/|terraform/|cloudformation/|\.github/workflows/|\.claude/}"
BLOCKER_MIGRATION_PATHS="${BLOCKER_MIGRATION_PATHS:-prisma/migrations/|migrations/|db/migrate/|alembic/}"
BLOCKER_AUTH_PATHS="${BLOCKER_AUTH_PATHS:-auth/|Auth|authentication|authorization|cognito|oauth}"
BLOCKER_DOC_PATHS="${BLOCKER_DOC_PATHS:-Technical-Specs|Architecture|CLAUDE.md|ARCHITECTURE.md}"
BLOCKER_PROTECTED_SCRIPTS="${BLOCKER_PROTECTED_SCRIPTS:-workflow-runner.sh|claude-workflow.sh|merge-pr.sh|create-pr.sh|batch-process-issues.sh}"
BLOCKER_EXPENSIVE_SERVICES="${BLOCKER_EXPENSIVE_SERVICES:-\brds\b|\baurora\b|\bnatgateway\b|\bnat_gateway\b|\bec2\b|\bfargate\b|\bsagemaker\b|\bredshift\b}"

# =============================================================================
# STEP 6: Export Everything
# =============================================================================

export RITE_PROJECT_ROOT
export RITE_PROJECT_NAME
export RITE_INSTALL_DIR
export RITE_LIB_DIR
export RITE_DATA_DIR
export RITE_WORKTREE_BASE
export RITE_WORKTREE_DIR
export RITE_MAX_ISSUES_PER_SESSION
export RITE_MAX_SESSION_HOURS
export RITE_MAX_RETRIES
export RITE_ASSESSMENT_TIMEOUT
export RITE_STALE_BRANCH_THRESHOLD
export WORKFLOW_MODE
export RITE_NOTIFICATIONS
export RITE_AWS_PROFILE
export RITE_SNS_TOPIC_ARN
export RITE_EMAIL_FROM
export SLACK_WEBHOOK
export EMAIL_NOTIFICATION_ADDRESS
export RITE_INTERNAL_DOCS_DIR
export SCRATCHPAD_FILE
export SESSION_STATE_FILE
export RITE_CLAUDE_TIMEOUT
export RITE_CLAUDE_MODEL
export RITE_REVIEW_MODEL
export RITE_DEV_PROVIDER
export RITE_REVIEW_PROVIDER
export RITE_UTILITY_PROVIDER
export RITE_GEMINI_DEV_MODEL
export RITE_GEMINI_REVIEW_MODEL
export RITE_PLAN_DOCS
export RITE_PLAN_MAX_ESTIMATE
export RITE_DRY_RUN
export RITE_SKIP_TESTS
export RITE_TEST_CMD
export BLOCKER_INFRASTRUCTURE_PATHS
export BLOCKER_MIGRATION_PATHS
export BLOCKER_AUTH_PATHS
export BLOCKER_DOC_PATHS
export BLOCKER_PROTECTED_SCRIPTS
export BLOCKER_EXPENSIVE_SERVICES

# =============================================================================
# STEP 6b: Timeout Command Detection
# =============================================================================
# Source the shared timeout utility and resolve RITE_TIMEOUT_CMD once.
# This sets RITE_TIMEOUT_CMD to "gtimeout", "timeout", or "" (unavailable).
# If missing, prompts to install coreutils (auto-installs in unsupervised mode).

if [ -f "$RITE_LIB_DIR/utils/timeout.sh" ]; then
  source "$RITE_LIB_DIR/utils/timeout.sh"
  ensure_timeout_cmd
fi

# =============================================================================
# STEP 7: Create Project Data Directory If Needed
# =============================================================================

if [ "$RITE_DRY_RUN" != "true" ]; then
  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"
  mkdir -p "$RITE_WORKTREE_DIR"

  # Create .rite/.gitignore if it doesn't exist
  RITE_GITIGNORE="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/.gitignore"
  if [ ! -f "$RITE_GITIGNORE" ] && [ -f "$RITE_INSTALL_DIR/templates/gitignore" ]; then
    cp "$RITE_INSTALL_DIR/templates/gitignore" "$RITE_GITIGNORE"
  fi

  # Create backward-compat symlink for .claude/scratch.md if .claude/ exists
  if [ -d "$RITE_PROJECT_ROOT/.claude" ] && [ ! -e "$RITE_PROJECT_ROOT/.claude/scratch.md" ]; then
    ln -sf "../$RITE_DATA_DIR/scratch.md" "$RITE_PROJECT_ROOT/.claude/scratch.md"
  fi
fi
