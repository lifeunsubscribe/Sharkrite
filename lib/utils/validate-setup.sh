#!/bin/bash
# lib/utils/validate-setup.sh
# Validate that workflow automation prerequisites are met
# Usage:
#   validate-setup.sh           # Check all prerequisites
#   validate-setup.sh --fix     # Auto-fix issues where possible

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_VALIDATE_SETUP_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_VALIDATE_SETUP_LOADED=true

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

set -euo pipefail

# Source scratchpad lock utilities (used when --fix writes to the scratchpad)
_VALIDATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f acquire_scratchpad_lock >/dev/null 2>&1; then
  source "$_VALIDATE_SCRIPT_DIR/scratchpad-lock.sh"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# Guard: when sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, stop here so tests can
# load only the function definitions without running the validation program
# (local-review.sh pattern). The program body below probes live machine state —
# gh auth, the gitignored .rite data dir, AWS credentials — and exits non-zero
# when any prerequisite is missing, so sourcing it makes the caller's exit code
# depend on the host environment (green on a set-up dev machine, red in clean CI).
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

FIX_MODE=false
if [ "${1:-}" = "--fix" ]; then
  FIX_MODE=true
fi

cd "$RITE_PROJECT_ROOT"

ISSUES_FOUND=0

print_header "🔍 Sharkrite Workflow Setup Validation"

# Check 1: Git repository
print_info "Checking Git repository..."
if git rev-parse --git-dir >/dev/null 2>&1; then
  print_success "Git repository found"
else
  print_error "Not a Git repository"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi
echo ""

# Check 2: Required CLI tools
print_info "Checking required CLI tools..."

REQUIRED_TOOLS=("gh" "jq" "git")
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    print_success "$tool is installed"
  else
    print_error "$tool is NOT installed"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))

    if [ "$FIX_MODE" = true ]; then
      print_info "Install: brew install $tool"
    fi
  fi
done
echo ""

# Check 3: GitHub CLI authentication
print_info "Checking GitHub CLI authentication..."
if gh auth status &>/dev/null; then
  print_success "GitHub CLI authenticated"
else
  print_error "GitHub CLI NOT authenticated"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))

  if [ "$FIX_MODE" = true ]; then
    print_info "Run: gh auth login"
  fi
fi
echo ""

# Check 4: AWS CLI configuration
print_info "Checking AWS CLI configuration..."
if command -v aws &>/dev/null; then
  if aws sts get-caller-identity &>/dev/null; then
    print_success "AWS credentials valid"
  else
    print_warning "AWS credentials expired or not configured"
    print_info "Run: aws sso login --profile ${RITE_AWS_PROFILE:-default}"
  fi
else
  print_warning "AWS CLI not installed (optional for some workflows)"
  print_info "Install: brew install awscli"
fi
echo ""

# Check 4b: Timeout command (auto-installs if missing via shared utility)
print_info "Checking timeout command..."
if [ -n "${RITE_TIMEOUT_CMD:-}" ]; then
  print_success "Timeout available ($RITE_TIMEOUT_CMD)"
else
  # Trigger the shared detection + install prompt
  if [ -f "$RITE_LIB_DIR/utils/timeout.sh" ]; then
    source "$RITE_LIB_DIR/utils/timeout.sh"
    ensure_timeout_cmd
  fi
  if [ -n "${RITE_TIMEOUT_CMD:-}" ]; then
    print_success "Timeout now available ($RITE_TIMEOUT_CMD)"
  else
    print_warning "No timeout command (workflows will run without timeout protection)"
  fi
fi
echo ""

# Check 5: Required directories
print_info "Checking required directories..."

REQUIRED_DIRS=(
  "$RITE_DATA_DIR"
)

for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    print_success "$dir exists"
  else
    print_error "$dir does NOT exist"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))

    if [ "$FIX_MODE" = true ]; then
      mkdir -p "$dir"
      print_success "Created: $dir"
      ISSUES_FOUND=$((ISSUES_FOUND - 1))
    fi
  fi
done
echo ""

# Check 6: Sharkrite installation
print_info "Checking rite installation..."

REQUIRED_RITE_DIRS=(
  "$RITE_LIB_DIR/utils"
  "$RITE_LIB_DIR/core"
)

for dir in "${REQUIRED_RITE_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    print_success "$dir exists"
  else
    print_error "$dir does NOT exist"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
  fi
done
echo ""

# Check 7: Required library scripts
print_info "Checking required library scripts..."

REQUIRED_LIBS=(
  "$RITE_LIB_DIR/utils/config.sh"
  "$RITE_LIB_DIR/utils/notifications.sh"
  "$RITE_LIB_DIR/utils/session-tracker.sh"
)

for lib in "${REQUIRED_LIBS[@]}"; do
  if [ -f "$lib" ]; then
    print_success "$(basename "$lib") exists"

    # Check if executable
    if [ -x "$lib" ]; then
      print_info "  ✓ Executable"
    else
      print_warning "  Not executable"

      if [ "$FIX_MODE" = true ]; then
        chmod +x "$lib"
        print_success "  Made executable"
      fi
    fi
  else
    print_error "$(basename "$lib") does NOT exist at $lib"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
  fi
done
echo ""

# Check 8: Required core scripts
print_info "Checking required core scripts..."

REQUIRED_SCRIPTS=(
  "$RITE_LIB_DIR/core/workflow-runner.sh"
  "$RITE_LIB_DIR/core/claude-workflow.sh"
  "$RITE_LIB_DIR/core/create-pr.sh"
  "$RITE_LIB_DIR/core/assess-and-resolve.sh"
  "$RITE_LIB_DIR/core/merge-pr.sh"
  "$RITE_LIB_DIR/core/batch-process-issues.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
  if [ -f "$script" ]; then
    print_success "$(basename "$script") exists"

    # Check if executable
    if [ -x "$script" ]; then
      print_info "  ✓ Executable"
    else
      print_warning "  Not executable"

      if [ "$FIX_MODE" = true ]; then
        chmod +x "$script"
        print_success "  Made executable"
      fi
    fi
  else
    print_error "$(basename "$script") does NOT exist at $script"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
  fi
done
echo ""

# Check 9: Scratchpad file
print_info "Checking scratchpad file..."

if [ -f "$SCRATCHPAD_FILE" ]; then
  print_success "Scratchpad exists at $SCRATCHPAD_FILE"

  # Check if it has required sections
  if grep -q "## Recent Security Findings" "$SCRATCHPAD_FILE"; then
    print_info "  ✓ Has 'Recent Security Findings' section"
  else
    print_warning "  Missing 'Recent Security Findings' section"

    if [ "$FIX_MODE" = true ]; then
      # Acquire lock before writing — validate-setup may run while workflows are
      # active. Contention returns 1: skip (advisory), re-run validate later.
      if ! acquire_scratchpad_lock; then
        print_warning "  Scratchpad lock busy — skipping section add (re-run validate-setup later)"
      else
      _setup_scratchpad_lock_trap
      cat >> "$SCRATCHPAD_FILE" <<'EOF'

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Check these before implementing new features._

---
EOF
      release_scratchpad_lock
      print_success "  Added 'Recent Security Findings' section"
      fi
    fi
  fi

  if grep -q "## Current Work" "$SCRATCHPAD_FILE"; then
    print_info "  ✓ Has 'Current Work' section"
  else
    print_warning "  Missing 'Current Work' section"

    if [ "$FIX_MODE" = true ]; then
      # Contention returns 1: skip (advisory), re-run validate later.
      if ! acquire_scratchpad_lock; then
        print_warning "  Scratchpad lock busy — skipping section add (re-run validate-setup later)"
      else
      _setup_scratchpad_lock_trap
      cat >> "$SCRATCHPAD_FILE" <<'EOF'

## Current Work

_No active work - start new issue with rite_

---
EOF
      release_scratchpad_lock
      print_success "  Added 'Current Work' section"
      fi
    fi
  fi
else
  print_warning "Scratchpad does NOT exist at $SCRATCHPAD_FILE"

  if [ "$FIX_MODE" = true ]; then
    # Initialize scratchpad with basic structure
    # Lock before creating so concurrent validate-setup --fix runs don't both write
    mkdir -p "$(dirname "$SCRATCHPAD_FILE")"
    # Contention returns 1: skip creation (advisory), re-run validate later.
    if ! acquire_scratchpad_lock; then
      print_warning "  Scratchpad lock busy — skipping scratchpad creation (re-run validate-setup later)"
    else
    _setup_scratchpad_lock_trap
    # Re-check after acquiring lock — another process may have created it
    if [ ! -f "$SCRATCHPAD_FILE" ]; then
      cat > "$SCRATCHPAD_FILE" <<'EOF'
# Sharkrite Scratchpad

**Purpose:** Working notes, security findings, and development context for Sharkrite

---

## 🔥 HIGH PRIORITY

_User-managed section - Claude does not auto-modify_

- Add your high-priority reminders here
- These persist across sessions

---

## Current Work

_No active work - start new issue with rite_

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Check these before implementing new features._

---

## Completed Work Archive

_Last 20 PRs - auto-cleaned_

---

_This file is for Claude's working memory only._
EOF
      print_success "Created scratchpad at $SCRATCHPAD_FILE"
    fi
    release_scratchpad_lock
    fi
  fi
fi
echo ""

# Check 10: Git configuration
print_info "Checking Git configuration..."

GIT_USER_NAME=$(git config user.name 2>/dev/null || echo "")
GIT_USER_EMAIL=$(git config user.email 2>/dev/null || echo "")

if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
  print_success "Git user configured"
  print_info "  Name: $GIT_USER_NAME"
  print_info "  Email: $GIT_USER_EMAIL"
else
  print_warning "Git user NOT configured"

  if [ "$FIX_MODE" = true ]; then
    print_info "Configure with: git config --global user.name 'Your Name'"
    print_info "Configure with: git config --global user.email 'you@example.com'"
  fi
fi
echo ""

# Check 11: Worktree base directory
print_info "Checking worktree base directory..."

if [ -d "$RITE_WORKTREE_DIR" ]; then
  print_success "Worktree base directory exists"
  print_info "  Path: $RITE_WORKTREE_DIR"
else
  print_info "Worktree base directory does NOT exist (will be created on first use)"

  if [ "$FIX_MODE" = true ]; then
    mkdir -p "$RITE_WORKTREE_DIR"
    print_success "Created: $RITE_WORKTREE_DIR"
  fi
fi
echo ""

# Check 12: Session tracking directory
print_info "Checking session tracking directory..."

SESSION_DIR="$RITE_DATA_DIR/sessions"

if [ -d "$SESSION_DIR" ]; then
  print_success "Session tracking directory exists"
else
  print_info "Session tracking directory does NOT exist (will be created on first use)"

  if [ "$FIX_MODE" = true ]; then
    mkdir -p "$SESSION_DIR"
    print_success "Created: $SESSION_DIR"
  fi
fi
echo ""

# Check 13: Review setup
print_info "Checking review setup..."

# The GitHub Actions auto-review workflow is deprecated; local reviews are used instead
WORKFLOW_FILE="$RITE_PROJECT_ROOT/.github/workflows/claude-code-review.yml"
INSTRUCTIONS_FILE="$RITE_PROJECT_ROOT/.github/claude-code/pr-review-instructions.md"

if [ -f "$WORKFLOW_FILE" ]; then
  print_warning "Found deprecated claude-code-review.yml — can be removed (local reviews are used instead)"
fi

if [ -f "$INSTRUCTIONS_FILE" ]; then
  print_success "Review instructions file found"
else
  print_warning "Review instructions file missing"
  print_info "Create: .github/claude-code/pr-review-instructions.md"
  print_info "Or run: rite --init (will offer to create it)"
fi
echo ""

# Check 14: Gitignore patterns for workflow artifacts
print_info "Checking .gitignore for workflow artifacts..."

GITIGNORE_FILE="$RITE_PROJECT_ROOT/.gitignore"
REQUIRED_IGNORES=(
  ".rite/"
  ".claude/"
  ".forge/"
)

if [ -f "$GITIGNORE_FILE" ]; then
  MISSING_IGNORES=()
  for pattern in "${REQUIRED_IGNORES[@]}"; do
    if ! grep -qF "$pattern" "$GITIGNORE_FILE"; then
      MISSING_IGNORES+=("$pattern")
    fi
  done

  if [ ${#MISSING_IGNORES[@]} -eq 0 ]; then
    print_success "All workflow artifact patterns in .gitignore"
  else
    print_warning "Missing gitignore patterns: ${MISSING_IGNORES[*]}"

    if [ "$FIX_MODE" = true ]; then
      echo "" >> "$GITIGNORE_FILE"
      echo "# Sharkrite workflow artifacts (auto-added by rite validate --fix)" >> "$GITIGNORE_FILE"
      for pattern in "${MISSING_IGNORES[@]}"; do
        echo "$pattern" >> "$GITIGNORE_FILE"
      done
      print_success "Added missing patterns to .gitignore"
    else
      print_info "Run 'rite validate --fix' to add them"
    fi
  fi
else
  print_warning ".gitignore does not exist"

  if [ "$FIX_MODE" = true ]; then
    echo "# Sharkrite workflow artifacts" > "$GITIGNORE_FILE"
    for pattern in "${REQUIRED_IGNORES[@]}"; do
      echo "$pattern" >> "$GITIGNORE_FILE"
    done
    print_success "Created .gitignore with workflow artifact patterns"
  else
    print_info "Run 'rite validate --fix' to create one"
  fi
fi
echo ""

# Summary
print_header "📊 Validation Summary"

if [ $ISSUES_FOUND -eq 0 ]; then
  print_success "All checks passed! Sharkrite workflow automation is ready to use."
  echo ""
  echo "Next steps:"
  echo "  1. Start workflow: rite ISSUE_NUMBER"
  echo "  2. Or batch process: rite 19 21"
  echo ""
  exit 0
else
  print_warning "Found $ISSUES_FOUND issue(s)"
  echo ""

  if [ "$FIX_MODE" = false ]; then
    echo "To auto-fix issues where possible:"
    echo "  rite validate --fix"
    echo ""
  fi

  exit 1
fi
