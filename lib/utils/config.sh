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
RITE_WORKTREE_BASE="${RITE_WORKTREE_BASE:-$HOME/Dev/rite-worktrees}"
RITE_WORKTREE_DIR="${RITE_WORKTREE_DIR:-$RITE_WORKTREE_BASE/${RITE_PROJECT_NAME}-worktrees}"

# Session limits
RITE_MAX_ISSUES_PER_SESSION="${RITE_MAX_ISSUES_PER_SESSION:-8}"
RITE_MAX_SESSION_HOURS="${RITE_MAX_SESSION_HOURS:-4}"
RITE_MAX_RETRIES="${RITE_MAX_RETRIES:-3}"
RITE_ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-120}"

# Workflow mode
WORKFLOW_MODE="${WORKFLOW_MODE:-supervised}"

# AWS/Notifications (optional - empty means disabled)
RITE_AWS_PROFILE="${RITE_AWS_PROFILE:-default}"
RITE_SNS_TOPIC_ARN="${RITE_SNS_TOPIC_ARN:-}"
RITE_EMAIL_FROM="${RITE_EMAIL_FROM:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_NOTIFICATION_ADDRESS="${EMAIL_NOTIFICATION_ADDRESS:-}"

# Internal docs directory
RITE_INTERNAL_DOCS_DIR="${RITE_INTERNAL_DOCS_DIR:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/docs}"

# Scratchpad
SCRATCHPAD_FILE="${SCRATCHPAD_FILE:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md}"

# Session state
SESSION_STATE_FILE="${SESSION_STATE_FILE:-/tmp/rite-session-state-${RITE_PROJECT_NAME}.json}"

# Sharkrite timeout (seconds, default 2 hours)
RITE_CLAUDE_TIMEOUT="${RITE_CLAUDE_TIMEOUT:-7200}"

# Claude model for development sessions (full ID so labels show exact version)
RITE_CLAUDE_MODEL="${RITE_CLAUDE_MODEL:-claude-sonnet-4-5-20250929}"

# Model for reviews and assessments — opus for quality (must match for consistency)
RITE_REVIEW_MODEL="${RITE_REVIEW_MODEL:-claude-opus-4-5-20251101}"

# Dry-run mode
RITE_DRY_RUN="${RITE_DRY_RUN:-false}"

# Skip AWS checks (for non-AWS projects)
SKIP_AWS_CHECK="${SKIP_AWS_CHECK:-true}"

# =============================================================================
# STEP 3: Load Global Config (~/.config/rite/config)
# =============================================================================

RITE_GLOBAL_CONFIG="${RITE_GLOBAL_CONFIG:-$HOME/.config/rite/config}"
safe_source "$RITE_GLOBAL_CONFIG"

# Also check ~/.riterc for convenience
safe_source "$HOME/.riterc"

# =============================================================================
# STEP 4: Load Project Config ($REPO/.rite/config)
# =============================================================================

RITE_PROJECT_CONFIG="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/config"
safe_source "$RITE_PROJECT_CONFIG"

# =============================================================================
# STEP 5: Load Blocker Rules (project-specific or defaults)
# =============================================================================

RITE_BLOCKERS_CONFIG="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/blockers.conf"
safe_source "$RITE_BLOCKERS_CONFIG"

# Blocker pattern defaults (if not set by project config)
BLOCKER_INFRASTRUCTURE_PATHS="${BLOCKER_INFRASTRUCTURE_PATHS:-infrastructure/|cdk/|terraform/|cloudformation/|\.github/workflows/|\.claude/}"
BLOCKER_MIGRATION_PATHS="${BLOCKER_MIGRATION_PATHS:-prisma/migrations/|migrations/|db/migrate/|alembic/}"
BLOCKER_AUTH_PATHS="${BLOCKER_AUTH_PATHS:-auth/|Auth|authentication|authorization|cognito|oauth}"
BLOCKER_DOC_PATHS="${BLOCKER_DOC_PATHS:-Technical-Specs|Architecture|CLAUDE.md|ARCHITECTURE.md}"
BLOCKER_PROTECTED_SCRIPTS="${BLOCKER_PROTECTED_SCRIPTS:-workflow-runner.sh|claude-workflow.sh|merge-pr.sh|create-pr.sh|batch-process-issues.sh}"
BLOCKER_EXPENSIVE_SERVICES="${BLOCKER_EXPENSIVE_SERVICES:-rds|aurora|nat|ec2|fargate|sagemaker|redshift}"

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
export WORKFLOW_MODE
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
export RITE_DRY_RUN
export SKIP_AWS_CHECK
export BLOCKER_INFRASTRUCTURE_PATHS
export BLOCKER_MIGRATION_PATHS
export BLOCKER_AUTH_PATHS
export BLOCKER_DOC_PATHS
export BLOCKER_PROTECTED_SCRIPTS
export BLOCKER_EXPENSIVE_SERVICES

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
