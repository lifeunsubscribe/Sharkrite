#!/bin/bash
# lib/utils/config.sh - Forge configuration loader
# Sources: defaults → global config → project config → env vars
#
# Priority (highest wins):
#   1. Environment variables (FORGE_*)
#   2. Project config ($REPO/.forge/config)
#   3. Global config (~/.config/forge/config or ~/.forgerc)
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
if [ -z "${FORGE_PROJECT_ROOT:-}" ]; then
  FORGE_PROJECT_ROOT="$(detect_project_root)"
fi

if [ -z "$FORGE_PROJECT_ROOT" ]; then
  echo "❌ Not inside a git repository. Run forge from within a project." >&2
  exit 1
fi

FORGE_PROJECT_NAME="${FORGE_PROJECT_NAME:-$(basename "$FORGE_PROJECT_ROOT")}"

# =============================================================================
# STEP 2: Set Defaults
# =============================================================================

# Installation paths (FORGE_INSTALL_DIR should be set by bin/forge before sourcing)
FORGE_INSTALL_DIR="${FORGE_INSTALL_DIR:-$HOME/.forge}"
FORGE_LIB_DIR="${FORGE_LIB_DIR:-$FORGE_INSTALL_DIR/lib}"

# Project data directory (per-repo, inside the repo)
FORGE_DATA_DIR="${FORGE_DATA_DIR:-.forge}"

# Worktrees (global, organized by project)
FORGE_WORKTREE_BASE="${FORGE_WORKTREE_BASE:-$HOME/Dev/forge-worktrees}"
FORGE_WORKTREE_DIR="${FORGE_WORKTREE_DIR:-$FORGE_WORKTREE_BASE/${FORGE_PROJECT_NAME}-worktrees}"

# Session limits
FORGE_MAX_ISSUES_PER_SESSION="${FORGE_MAX_ISSUES_PER_SESSION:-8}"
FORGE_MAX_SESSION_HOURS="${FORGE_MAX_SESSION_HOURS:-4}"
FORGE_MAX_RETRIES="${FORGE_MAX_RETRIES:-3}"
FORGE_ASSESSMENT_TIMEOUT="${FORGE_ASSESSMENT_TIMEOUT:-120}"

# Workflow mode
WORKFLOW_MODE="${WORKFLOW_MODE:-supervised}"

# AWS/Notifications (optional - empty means disabled)
FORGE_AWS_PROFILE="${FORGE_AWS_PROFILE:-default}"
FORGE_SNS_TOPIC_ARN="${FORGE_SNS_TOPIC_ARN:-}"
FORGE_EMAIL_FROM="${FORGE_EMAIL_FROM:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_NOTIFICATION_ADDRESS="${EMAIL_NOTIFICATION_ADDRESS:-}"

# Scratchpad
SCRATCHPAD_FILE="${SCRATCHPAD_FILE:-$FORGE_PROJECT_ROOT/$FORGE_DATA_DIR/scratch.md}"

# Session state
SESSION_STATE_FILE="${SESSION_STATE_FILE:-/tmp/forge-session-state-${FORGE_PROJECT_NAME}.json}"

# Claude Code timeout (seconds, default 2 hours)
FORGE_CLAUDE_TIMEOUT="${FORGE_CLAUDE_TIMEOUT:-7200}"

# Dry-run mode
FORGE_DRY_RUN="${FORGE_DRY_RUN:-false}"

# Skip AWS checks (for non-AWS projects)
SKIP_AWS_CHECK="${SKIP_AWS_CHECK:-true}"

# =============================================================================
# STEP 3: Load Global Config (~/.config/forge/config)
# =============================================================================

FORGE_GLOBAL_CONFIG="${FORGE_GLOBAL_CONFIG:-$HOME/.config/forge/config}"
safe_source "$FORGE_GLOBAL_CONFIG"

# Also check ~/.forgerc for convenience
safe_source "$HOME/.forgerc"

# =============================================================================
# STEP 4: Load Project Config ($REPO/.forge/config)
# =============================================================================

FORGE_PROJECT_CONFIG="$FORGE_PROJECT_ROOT/$FORGE_DATA_DIR/config"
safe_source "$FORGE_PROJECT_CONFIG"

# =============================================================================
# STEP 5: Load Blocker Rules (project-specific or defaults)
# =============================================================================

FORGE_BLOCKERS_CONFIG="$FORGE_PROJECT_ROOT/$FORGE_DATA_DIR/blockers.conf"
safe_source "$FORGE_BLOCKERS_CONFIG"

# Blocker pattern defaults (if not set by project config)
BLOCKER_INFRASTRUCTURE_PATHS="${BLOCKER_INFRASTRUCTURE_PATHS:-infrastructure/|cdk/|terraform/|cloudformation/}"
BLOCKER_MIGRATION_PATHS="${BLOCKER_MIGRATION_PATHS:-prisma/migrations/|migrations/|db/migrate/|alembic/}"
BLOCKER_AUTH_PATHS="${BLOCKER_AUTH_PATHS:-auth/|Auth|authentication|authorization|cognito|oauth}"
BLOCKER_DOC_PATHS="${BLOCKER_DOC_PATHS:-Technical-Specs|Architecture|CLAUDE.md|ARCHITECTURE.md}"
BLOCKER_PROTECTED_SCRIPTS="${BLOCKER_PROTECTED_SCRIPTS:-workflow-runner.sh|claude-workflow.sh|merge-pr.sh|create-pr.sh|batch-process-issues.sh}"
BLOCKER_EXPENSIVE_SERVICES="${BLOCKER_EXPENSIVE_SERVICES:-rds|aurora|nat|ec2|fargate|sagemaker|redshift}"

# =============================================================================
# STEP 6: Export Everything
# =============================================================================

export FORGE_PROJECT_ROOT
export FORGE_PROJECT_NAME
export FORGE_INSTALL_DIR
export FORGE_LIB_DIR
export FORGE_DATA_DIR
export FORGE_WORKTREE_BASE
export FORGE_WORKTREE_DIR
export FORGE_MAX_ISSUES_PER_SESSION
export FORGE_MAX_SESSION_HOURS
export FORGE_MAX_RETRIES
export FORGE_ASSESSMENT_TIMEOUT
export WORKFLOW_MODE
export FORGE_AWS_PROFILE
export FORGE_SNS_TOPIC_ARN
export FORGE_EMAIL_FROM
export SLACK_WEBHOOK
export EMAIL_NOTIFICATION_ADDRESS
export SCRATCHPAD_FILE
export SESSION_STATE_FILE
export FORGE_CLAUDE_TIMEOUT
export FORGE_DRY_RUN
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

if [ "$FORGE_DRY_RUN" != "true" ]; then
  mkdir -p "$FORGE_PROJECT_ROOT/$FORGE_DATA_DIR"
  mkdir -p "$FORGE_WORKTREE_DIR"

  # Create .forge/.gitignore if it doesn't exist
  FORGE_GITIGNORE="$FORGE_PROJECT_ROOT/$FORGE_DATA_DIR/.gitignore"
  if [ ! -f "$FORGE_GITIGNORE" ] && [ -f "$FORGE_INSTALL_DIR/templates/gitignore" ]; then
    cp "$FORGE_INSTALL_DIR/templates/gitignore" "$FORGE_GITIGNORE"
  fi

  # Create backward-compat symlink for .claude/scratch.md if .claude/ exists
  if [ -d "$FORGE_PROJECT_ROOT/.claude" ] && [ ! -e "$FORGE_PROJECT_ROOT/.claude/scratch.md" ]; then
    ln -sf "../$FORGE_DATA_DIR/scratch.md" "$FORGE_PROJECT_ROOT/.claude/scratch.md"
  fi
fi
