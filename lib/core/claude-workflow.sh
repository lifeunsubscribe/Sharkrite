#!/bin/bash
# scripts/claude-workflow.sh
# Unified workflow entry point - handles all modes of starting/continuing work
#
# Usage Examples:
#   rite 19                            # From GitHub issue (supervised)
#   rite 19 --quick                    # From GitHub issue (unsupervised)
#   rite "add oauth"                   # From description (supervised)
#   rite --continue                    # Continue work on existing branch
#
# Features:
#   - Smart worktree detection (auto-navigates to existing worktrees)
#   - Automatic stashing/unstashing
#   - Auto-cleanup at worktree limit (merged branches, stale worktrees)
#   - Scratchpad integration (loads recent security findings)
#   - Zero unnecessary prompts (only ambiguity or genuine blockers)

set -euo pipefail

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Source session tracker for interrupt state saving
source "$RITE_LIB_DIR/utils/session-tracker.sh"

# Source provider abstraction
source "$RITE_LIB_DIR/providers/provider-interface.sh"
load_provider "${RITE_DEV_PROVIDER:-claude}"

# Source timeout wrapper (config.sh sources it, but is skipped when RITE_LIB_DIR is pre-set)
if [ -f "$RITE_LIB_DIR/utils/timeout.sh" ] && ! declare -f run_with_timeout >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/timeout.sh"
  ensure_timeout_cmd
fi

# Store the absolute path to THIS script for re-execution
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Early output to confirm script is running (skip on re-entry from worktree navigation)
if [ -z "${CONTINUE_ISSUE_NUM:-}" ]; then
  echo "🦈 Initializing Sharkrite workflow..."
  echo ""
fi

# Trap handler for safe exit on interrupt
cleanup_on_interrupt() {
  local exit_code=$?

  echo ""
  echo -e "\033[1;33m⚠️  Workflow interrupted!\033[0m"

  # Check if we're in a worktree
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    local current_dir=$(pwd)
    local main_repo
    main_repo=$(git worktree list | head -1 | awk '{print $1}')

    # Check for uncommitted changes (exclude untracked files)
    local uncommitted
    uncommitted=$(git status --porcelain | grep -vE "^\?\?" | { grep -v "\.gitignore$" || true; } | wc -l | tr -d ' ')

    if [ "$uncommitted" -gt 0 ]; then
      echo -e "\033[0;34mℹ️  Found $uncommitted uncommitted change(s)\033[0m"

      if [ "$AUTO_MODE" = true ]; then
        # In auto mode, always commit WIP
        local branch_name
        branch_name=$(git branch --show-current)
        local commit_msg="WIP: interrupted work on ${branch_name}"

        git add -A
        git commit -m "$commit_msg" 2>/dev/null || true
        echo -e "\033[0;32m✅ Changes committed: $commit_msg\033[0m"

        # Push in auto mode
        git push -u origin "$branch_name" 2>/dev/null || echo -e "\033[1;33m⚠️  Push failed (changes are committed locally)\033[0m"
      else
        # In supervised mode, ask the user
        read -p "Commit changes before exiting? (y/n) " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
          local branch_name
          branch_name=$(git branch --show-current)
          local commit_msg="WIP: interrupted work on ${branch_name}"

          git add -A
          git commit -m "$commit_msg" 2>/dev/null || true
          echo -e "\033[0;32m✅ Changes committed\033[0m"

          read -p "Push to remote? (y/n) " -n 1 -r
          echo
          if [[ $REPLY =~ ^[Yy]$ ]]; then
            git push -u origin "$branch_name" 2>/dev/null || echo -e "\033[1;33m⚠️  Push failed\033[0m"
          fi
        fi
      fi
    fi

    # Save session state for resume if we have enough context
    if [ -n "${ISSUE_NUMBER:-}" ] && [ -n "$current_dir" ]; then
      save_session_state "${ISSUE_NUMBER}" "interrupted" "$current_dir" 2>/dev/null || true
      echo -e "\033[0;34mℹ️  Session state saved — run 'rite ${ISSUE_NUMBER}' to resume\033[0m"
    fi

    # Navigate back to main repo if in worktree
    if [ -n "$main_repo" ] && [ "$current_dir" != "$main_repo" ]; then
      echo -e "\033[0;34mℹ️  Returning to main repository...\033[0m"
      cd "$main_repo" || cd "$HOME"
      echo -e "\033[0;32m✅ Exited worktree: $current_dir\033[0m"
      echo -e "\033[0;34mℹ️  Your work is preserved in the worktree\033[0m"
    fi
  fi

  # Terminate entire process group to ensure all child processes (tee, perl, etc.) are killed.
  # Use SIGTERM first for graceful shutdown, then SIGKILL after brief delay if needed.
  # The negative PID (-$$) sends signal to all processes in the current process group.
  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.5
  kill -KILL -- -$$ 2>/dev/null || true

  exit ${exit_code}
}

trap cleanup_on_interrupt INT TERM HUP

# Parse arguments - Two-pass to detect flags before processing issue number
AUTO_MODE=false
FIX_REVIEW_MODE=false
ISSUE_NUMBER=""
ISSUE_DESC=""
FIX_PR_NUMBER=""

# First pass: detect flags
for arg in "$@"; do
  case $arg in
    --auto) AUTO_MODE=true ;;
    --fix-review) FIX_REVIEW_MODE=true ;;
    --pr-number=*) FIX_PR_NUMBER="${arg#*=}" ;;
  esac
done

# Second pass: process issue number or description
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto|--fix-review)
      # Already processed in first pass
      shift
      ;;
    --pr-number)
      # Next arg is the PR number
      FIX_PR_NUMBER="$2"
      shift 2
      ;;
    --pr-number=*)
      # Already processed in first pass
      shift
      ;;
    *)
      # In fix-review mode, skip GitHub API calls (we only need issue number)
      if [ "$FIX_REVIEW_MODE" = true ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_NUMBER="$1"
        shift
      # Normal mode: fetch issue details from GitHub
      elif [[ "$1" =~ ^[0-9]+$ ]]; then
        # If normalization already ran (called from bin/rite or workflow-runner.sh),
        # skip internal issue parsing — just grab the issue number
        if [ -n "${NORMALIZED_SUBJECT:-}" ] && [ -n "${WORK_DESCRIPTION:-}" ]; then
          ISSUE_NUMBER="$1"
          ISSUE_DESC="${NORMALIZED_SUBJECT}"
          print_success "Issue: $ISSUE_DESC"
          shift
        else
          # Validate issue number is a positive integer
          if [ "$1" -le 0 ] 2>/dev/null; then
            echo "❌ Invalid issue number: $1 (must be positive integer)"
            exit 1
          fi
          ISSUE_NUMBER="$1"
          echo "▶  Fetching issue #$ISSUE_NUMBER from GitHub..."
          # Fetch issue details from GitHub
          ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --json title,body,state 2>/dev/null || echo "")
          if [ -n "$ISSUE_JSON" ] && [ "$ISSUE_JSON" != "null" ]; then
            ISSUE_DESC=$(echo "$ISSUE_JSON" | jq -r '.title')
            ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
            ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')

            # Validate issue has meaningful content
            if [ -z "$ISSUE_DESC" ] || [ "$ISSUE_DESC" = "null" ]; then
              echo "❌ Issue #$ISSUE_NUMBER has no title"
              echo "   Cannot proceed without a task description"
              exit 1
            fi

            # Warn if body is empty (but don't fail - title might be enough)
            if [ -z "$ISSUE_BODY" ] || [ "$ISSUE_BODY" = "null" ]; then
              echo "⚠️  Issue #$ISSUE_NUMBER has no description body"
              echo "   Will use title only: $ISSUE_DESC"
            fi

            # Warn if issue is closed
            if [ "$ISSUE_STATE" = "CLOSED" ]; then
              echo "⚠️  Issue #$ISSUE_NUMBER is already CLOSED"
              echo "   Proceeding anyway (may be reopening work)"
            fi

            echo "✅ Issue loaded: $ISSUE_DESC"
          else
            echo "❌ Issue #$ISSUE_NUMBER not found on GitHub"
            exit 1
          fi
          shift
        fi
      else
        ISSUE_DESC="$1"
        shift
      fi
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_status() { echo -e "${BLUE}$1${NC}"; }
print_step() { echo -e "${CYAN}▶  $1${NC}"; }


# Verbose-aware output (requires RITE_VERBOSE=true or --supervised)
source "$RITE_LIB_DIR/utils/logging.sh"

# ===================================================================
# TEST GATE (shared by dev and fix-review paths)
# Auto mode: always run unless RITE_SKIP_TESTS=true (default: run).
# Supervised mode: prompt the user.
# Exit code 3 = test failure in auto mode (detected by workflow-runner.sh as test_failures blocker).
# ===================================================================
run_test_gate() {
  local _should_run=false
  if [ "$AUTO_MODE" = true ]; then
    if [ "${RITE_SKIP_TESTS:-false}" = "true" ]; then
      print_info "Skipping tests (RITE_SKIP_TESTS=true)"
      return 0
    fi
    _should_run=true
  else
    read -p "🧪 Run tests before committing? (y/n) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && _should_run=true
  fi

  if [ "$_should_run" != true ]; then
    return 0
  fi

  # Detect test command: RITE_TEST_CMD override → auto-detect from project structure
  local _test_cmd="${RITE_TEST_CMD:-}"
  local _test_subdir=""

  if [ -z "$_test_cmd" ]; then
    if [ -f "package.json" ]; then
      _test_cmd="npm test"
    elif [ -f "backend/package.json" ]; then
      _test_cmd="npm test"
      _test_subdir="backend"
    elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || [ -f "setup.cfg" ] || [ -f "setup.py" ] || [ -d "tests" ]; then
      # If no venv exists yet but requirements.txt does, create one so the gate
      # doesn't fail with "No module named pytest" on the system python.
      if [ ! -f ".venv/bin/python" ] && [ ! -f "venv/bin/python" ] && [ ! -f "env/bin/python" ] && [ -f "requirements.txt" ]; then
        print_status "No venv found — creating .venv and installing requirements..."
        python3 -m venv .venv 2>/dev/null && .venv/bin/pip install -q -r requirements.txt 2>/dev/null || true
      fi
      # Prefer venv python (already has dependencies installed) over system python
      if [ -f ".venv/bin/python" ]; then
        _test_cmd=".venv/bin/python -m pytest"
      elif [ -f "venv/bin/python" ]; then
        _test_cmd="venv/bin/python -m pytest"
      elif [ -f "env/bin/python" ]; then
        _test_cmd="env/bin/python -m pytest"
      elif [ -n "${RITE_PROJECT_ROOT:-}" ] && [ -f "$RITE_PROJECT_ROOT/.venv/bin/python" ]; then
        _test_cmd="$RITE_PROJECT_ROOT/.venv/bin/python -m pytest"
      elif command -v python3 >/dev/null 2>&1; then
        _test_cmd="python3 -m pytest"
      else
        _test_cmd="python -m pytest"
      fi
    elif [ -f "Makefile" ] && grep -q "^test:" "Makefile" 2>/dev/null; then
      _test_cmd="make test"
    fi
  fi

  if [ -z "$_test_cmd" ]; then
    print_warning "No test runner detected — skipping tests"
    return 0
  fi

  # Optimize pytest: parallelize, suppress noise, offer xdist install
  if echo "$_test_cmd" | grep -q "pytest"; then
    local _python_bin
    _python_bin=$(echo "$_test_cmd" | sed 's/ -m pytest.*//')

    # Parallel execution via xdist (use if already installed, never auto-install)
    if ! echo "$_test_cmd" | grep -qE "\-n "; then
      if $_python_bin -c "import xdist" 2>/dev/null; then
        _test_cmd="$_test_cmd -n auto"
      fi
    fi

    # Short tracebacks, suppress deprecation warnings, quiet output
    _test_cmd="$_test_cmd --tb=short -W ignore::DeprecationWarning -q"
  fi

  # Source .env.test or .env if present so tests have required env vars
  # (e.g. JWT_SECRET_KEY, DATABASE_URL). Run in subshell to avoid polluting
  # the outer environment.
  local _env_file=""
  [ -f ".env.test" ] && _env_file=".env.test"
  [ -z "$_env_file" ] && [ -f ".env" ] && _env_file=".env"

  _timer_start "test_gate"
  print_status "Running tests ($_test_cmd)..."
  local _test_exit=0
  local _test_output_file
  _test_output_file=$(mktemp)
  _run_test_cmd() {
    if [ -n "$_env_file" ]; then
      set -a
      # shellcheck disable=SC1090
      source "$_env_file" 2>/dev/null || true
      set +a
    fi
    eval "$_test_cmd"
  }
  if [ -n "$_test_subdir" ]; then
    (cd "$_test_subdir" && _run_test_cmd) 2>&1 | tee "$_test_output_file" || _test_exit=${PIPESTATUS[0]:-$?}
  else
    (_run_test_cmd) 2>&1 | tee "$_test_output_file" || _test_exit=${PIPESTATUS[0]:-$?}
  fi

  _timer_end "test_gate"

  if [ "$_test_exit" -eq 0 ]; then
    print_success "All tests passed"
    rm -f "$_test_output_file"
  else
    print_warning "Tests failed (exit $_test_exit)"
    if [ "$AUTO_MODE" = true ]; then
      # Auto-fix: run a quick Claude session to fix test failures
      if [ "${_test_fix_attempted:-false}" != "true" ]; then
        _test_fix_attempted=true
        print_status "Running auto-fix session for test failures..."

        # Extract the FAILURES section (pytest prints this between ===== FAILURES =====
        # and ===== short test summary =====). Falls back to grep if section not found.
        local _fail_summary
        _fail_summary=$(sed -n '/=* FAILURES =*/,/=* short test summary/p' "$_test_output_file" | tail -80)
        if [ -z "$_fail_summary" ]; then
          _fail_summary=$(grep -E "FAILED|ERROR|AssertionError|assert|Error:" "$_test_output_file" | tail -30)
        fi
        # Also grab the summary line (e.g., "2 failed, 864 passed")
        local _fail_counts
        _fail_counts=$(grep -E "failed.*passed|error.*passed" "$_test_output_file" | tail -1)

        local _fix_prompt="Tests are failing after your implementation. Fix ALL failing tests — not just the first one.

**Test command:** $_test_cmd
**Test summary:** ${_fail_counts:-see output below}
**Full failure output:**
$_fail_summary

**Instructions:**
- Read the failing test files and the source code they test
- Identify the ROOT CAUSE, then scan the entire test file for every instance of the same pattern — not just the lines that failed. If one test has a timezone mismatch, check ALL tests in that file for the same issue.
- Fix the root cause (could be in source code OR test expectations)
- Do NOT run the full test suite — just fix the code. The workflow will re-run tests after.
- Do NOT run git commit, git push, or any git/gh commands."

        _timer_start "test_fix_session"
        local _fix_exit=0
        provider_run_agentic_session "$_fix_prompt" "${RITE_FIX_TIMEOUT:-1800}" true /dev/null || _fix_exit=$?
        _timer_end "test_fix_session"

        if [ $_fix_exit -eq 0 ]; then
          # Re-run tests after fix
          print_status "Re-running tests after fix..."
          rm -f "$_test_output_file"
          _test_exit=0
          _timer_start "test_gate_rerun"
          if [ -n "$_test_subdir" ]; then
            (cd "$_test_subdir" && _run_test_cmd) 2>&1 | tee "$_test_output_file" || _test_exit=${PIPESTATUS[0]:-$?}
          else
            (_run_test_cmd) 2>&1 | tee "$_test_output_file" || _test_exit=${PIPESTATUS[0]:-$?}
          fi
          _timer_end "test_gate_rerun"

          if [ "$_test_exit" -eq 0 ]; then
            print_success "All tests passed after fix"
            rm -f "$_test_output_file"
            return 0
          fi
          print_warning "Tests still failing after auto-fix"
        fi
      fi

      print_error "Cannot commit — test suite must pass in auto mode"
      print_info "Fix failures and resume: rite ${ISSUE_NUMBER:-}"
      print_info "To skip the test gate: export RITE_SKIP_TESTS=true"
      rm -f "$_test_output_file"
      exit 3
    else
      echo ""
      read -p "Continue with commit anyway? (y/n) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Fix tests and run again"
        rm -f "$_test_output_file"
        exit 1
      fi
    fi
    rm -f "$_test_output_file"
  fi
}

# ===================================================================
# EARLY EXIT FOR FIX-REVIEW MODE
# Must run before any worktree navigation to preserve stdin
# ===================================================================
if [ "$FIX_REVIEW_MODE" = true ]; then
  # Jump directly to fix-review logic (defined later in file)
  # Provider already loaded at top of file
  provider_detect_cli || exit 1

  # Now run the fix-review logic inline
  print_header "🔧 Review Fix Mode"

  # Fetch latest assessment from PR comment (single source of truth)
  if [ -n "$FIX_PR_NUMBER" ]; then
    print_status "Fetching latest assessment from PR #$FIX_PR_NUMBER..."
    REVIEW_CONTENT=$(gh pr view "$FIX_PR_NUMBER" --json comments \
      --jq '[.comments[] | select(.body | contains("<!-- sharkrite-assessment"))] | sort_by(.createdAt) | reverse | .[0].body' \
      2>/dev/null || echo "")

    # Strip the assessment header metadata (everything before the --- separator)
    # to give Claude just the assessment items
    if [ -n "$REVIEW_CONTENT" ] && echo "$REVIEW_CONTENT" | grep -q "^---$"; then
      REVIEW_CONTENT=$(echo "$REVIEW_CONTENT" | sed -n '/^---$/,$p' | tail -n +2)
    fi
  else
    print_status "No PR number provided, reading review content from stdin..."
    REVIEW_CONTENT=$(cat)
  fi

  if [ -z "$REVIEW_CONTENT" ] || [ "$REVIEW_CONTENT" = "null" ]; then
    print_error "No assessment found on PR #${FIX_PR_NUMBER:-unknown}"
    print_info "Expected a comment with <!-- sharkrite-assessment --> marker"
    exit 1
  fi

  print_info "Review content received ($(echo "$REVIEW_CONTENT" | wc -l) lines)"

  # Extract ONLY the ACTIONABLE_NOW items from the assessment
  # Assessment format: ### Title - ACTIONABLE_NOW\n**Severity:** ...\n**Category:** ...\n...
  # Each item runs from its ### header to the next ### header (or EOF)
  ACTIONABLE_NOW_ITEMS=$(echo "$REVIEW_CONTENT" | awk '
    /^### .* - ACTIONABLE_NOW$/ { printing=1 }
    /^### .* - (ACTIONABLE_LATER|DISMISSED)$/ { printing=0 }
    /^(✅|───|━━)/ { printing=0 }
    printing { print }
  ')

  if [ -z "$ACTIONABLE_NOW_ITEMS" ]; then
    print_warning "No ACTIONABLE_NOW items found in assessment — nothing to fix"
    exit 0
  fi

  ACTIONABLE_NOW_COUNT=$(echo "$ACTIONABLE_NOW_ITEMS" | grep -c "^### .* - ACTIONABLE_NOW" || true)

  # Build fix prompt - tool restrictions are enforced by --disallowedTools flag
  FIX_PROMPT="You are running inside a **Sharkrite** (CLI: \`rite\`) fix-review session.
Do NOT run git commit, git push, gh pr create, or any git/gh commands yourself.

## Review Issues to Fix ($ACTIONABLE_NOW_COUNT items)

The assessment identified the following issues that MUST be fixed in this PR.
Each item includes a title, severity, location, and fix effort estimate.
Fix ONLY these specific items — do not look for other issues.

$ACTIONABLE_NOW_ITEMS
"

  if [ "$AUTO_MODE" = true ]; then
    EXIT_INSTRUCTION="Session will end automatically when you finish making all fixes."
  else
    EXIT_INSTRUCTION="When you have finished making all fixes, immediately exit with \`/exit\`. The rite workflow will handle commit and push."
  fi

  FIX_PROMPT+="## Instructions

1. **Fix each ACTIONABLE_NOW item above** - the title, location, and fix effort are provided. Do NOT fetch PR comments or look for other issues — everything you need is in this prompt
2. **Make the necessary code changes** at the locations specified in each item
3. **After all fixes, re-read every file you modified from top to bottom** - verify no new issues were introduced and that the fix didn't leave a parallel instance of the same vulnerability elsewhere in the file
4. **Check for partial fixes** - for each issue, confirm the vulnerable pattern doesn't appear in any other location in the same file (e.g. if you fixed role assignment in one function, check every other function that writes role)

The workflow will automatically commit, push, and request a new review.

## Scope
- Read and edit source code files to fix the listed issues
- Run tests if mentioned in the issue
- Do NOT modify workflow, config, or CI files (.rite/, .github/workflows/, .claude/)

$EXIT_INSTRUCTION"

  print_status "Invoking Sharkrite to fix review issues..."
  echo ""

  # Run provider with the fix prompt
  FIX_TIMEOUT=${RITE_FIX_TIMEOUT:-1800}

  if [ "$AUTO_MODE" = true ]; then
    # Safety gate: provider must support tool restrictions for unsupervised mode
    if ! provider_supports_tool_restrictions; then
      print_error "Provider '$(provider_name)' does not support tool restrictions"
      print_error "Unsupervised fix sessions require tool restriction support"
      print_info "Use --supervised mode, or set RITE_DEV_PROVIDER=claude"
      exit 1
    fi

    _timer_start "claude_fix_session"
    print_status "Auto mode: $(provider_name) will exit automatically when fixes complete (timeout: ${FIX_TIMEOUT}s)"
    set +e
    FIX_STDERR_FILE=$(mktemp)

    provider_run_agentic_session "$FIX_PROMPT" "$FIX_TIMEOUT" true "$FIX_STDERR_FILE"
    FIX_EXIT_CODE=$?

    rm -f "$FIX_STDERR_FILE"
    set -e

    if [ $FIX_EXIT_CODE -eq 124 ]; then
      print_warning "Fix timeout reached (${FIX_TIMEOUT}s) - checking for changes..."
      # Even on timeout, we might have partial fixes
      if [ "$(git status --porcelain | grep -vE '^\?\?' | { grep -v '\.gitignore$' || true; } | wc -l | tr -d ' ')" -gt 0 ]; then
        print_info "Found uncommitted changes - will commit what we have"
      else
        print_error "No fixes made before timeout"
        exit 1
      fi
    elif [ $FIX_EXIT_CODE -ne 0 ]; then
      print_warning "$(provider_name) exited with code $FIX_EXIT_CODE - checking for changes..."
    fi
  else
    SUPERVISED_TIMEOUT=${RITE_SUPERVISED_TIMEOUT:-3600}  # Default 1 hour
    print_info "Supervised mode: Interactive fix session (timeout: ${SUPERVISED_TIMEOUT}s)"
    print_status "Tool restrictions active: gh, curl, wget blocked"
    print_status "Exit the session when fixes are complete."

    set +e
    provider_run_agentic_session "$FIX_PROMPT" "$SUPERVISED_TIMEOUT" false /dev/null
    FIX_EXIT_CODE=$?
    set -e

    if [ "${FIX_EXIT_CODE:-0}" -eq 124 ]; then
      print_warning "Supervised session timed out after ${SUPERVISED_TIMEOUT}s"
    fi
  fi

  _timer_end "claude_fix_session"
  print_success "Review fix session complete"

  # Run test gate before committing fixes (same gate as dev phase).
  # Without this, review fixes that break tests slip through to merge.
  run_test_gate

  # Commit and push the fixes
  print_status "Committing fixes..."
  git add -A

  # Generate commit message based on review content summary
  COMMIT_MSG="fix: address review findings from PR automated review

Auto-generated commit addressing issues identified in PR review.
See PR comments for detailed list of fixes applied.

Changes made via automated workflow (rite --fix-review mode)."

  git commit -m "$COMMIT_MSG" || {
    print_warning "No changes to commit"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Possible reasons:"
    echo "  • Issues were already fixed in a previous commit"
    echo "  • Claude skipped issues (out-of-scope or protected files)"
    echo "  • Issues don't require code changes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "The cached assessment may be stale"
    print_info "A new review will see the current state and assess fresh"
    # Don't exit with error - let workflow continue to request new review
    # The new review will see current state and assess fresh
  }

  print_status "Pushing fixes to remote..."
  if ! git push; then
    # Push failed — check for remote divergence
    print_warning "Push rejected — checking for divergence"
    source "$RITE_LIB_DIR/utils/divergence-handler.sh"

    _div_branch=$(git branch --show-current)
    if detect_divergence "$_div_branch"; then
      handle_push_divergence "$_div_branch" "${ISSUE_NUMBER:-}" "${FIX_PR_NUMBER:-}" "$AUTO_MODE" || {
        print_error "Could not resolve divergence during fix-review push"
        exit 1
      }
    else
      print_error "Push failed (not a divergence issue)"
      exit 1
    fi
  fi

  print_success "Fixes committed and pushed successfully"
  exit 0
fi

# Find worktree for given issue number
# Returns: "worktree_path|branch_name" or empty string
find_worktree_for_task() {
  local task="$1"  # Could be issue number OR description
  local result=""
  local pr_branch=""

  # If task is a number, it's an issue number - search by linked PR
  if [[ "$task" =~ ^[0-9]+$ ]]; then
    # Check if this is a follow-up issue with parent PR
    local issue_body=$(gh issue view "$task" --json body --jq '.body' 2>/dev/null || echo "")

    if echo "$issue_body" | grep -q "sharkrite-parent-pr:"; then
      # Extract parent PR number from body marker
      local parent_pr=$(echo "$issue_body" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2)

      if [ -n "$parent_pr" ]; then
        pr_branch=$(gh pr view "$parent_pr" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

        if [ -n "$pr_branch" ] && [ "$pr_branch" != "null" ]; then
          # Found parent PR's branch - this follow-up should work on same branch
          # Continue below to find worktree
          :
        fi
      fi
    fi

    # If not a follow-up or couldn't find parent, use normal logic
    if [ -z "$pr_branch" ] || [ "$pr_branch" = "null" ]; then
      # Get issue title for better PR matching
      local issue_title=$(gh issue view "$task" --json title --jq '.title' 2>/dev/null || echo "")

      # Try to find PR linked to this issue (searches body for "Closes #XX" pattern)
      # NOTE: GitHub search doesn't support exact pattern matching, so we fetch all PRs and filter
      pr_branch=$(gh pr list --state all --json headRefName,body --limit 100 2>/dev/null | \
        jq --arg issue "$task" -r '.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .headRefName' | \
        head -1)

      # If no PR found by issue link, try title matching
      if [ -z "$pr_branch" ] || [ "$pr_branch" = "null" ]; then
        if [ -n "$issue_title" ] && [ "$issue_title" != "null" ]; then
          pr_branch=$(gh pr list --json headRefName,title --limit 50 2>/dev/null | \
            jq --arg title "$issue_title" -r '.[] | select(.title | ascii_downcase | contains($title | ascii_downcase)) | .headRefName' | \
            head -1)
        fi
      fi
    fi
  else
    # Task is a description - search PRs by title similarity
    pr_branch=$(gh pr list --json headRefName,title --limit 50 2>/dev/null | \
      jq --arg title "$task" -r '.[] | select(.title | ascii_downcase | contains($title | ascii_downcase)) | .headRefName' | \
      head -1)
  fi

  # If we found a PR, find the worktree with that branch
  if [ -n "$pr_branch" ] && [ "$pr_branch" != "null" ]; then
    while IFS= read -r worktree_line; do
      local wt_path=$(echo "$worktree_line" | awk '{print $1}')
      local wt_branch=$(echo "$worktree_line" | grep -oE '\[[^]]+\]' | tr -d '[]' || echo "")

      if [ "$wt_branch" = "$pr_branch" ]; then
        result="${wt_path}|${wt_branch}"
        break
      fi
    done < <(git worktree list | tail -n +2)
  fi

  echo "$result"
}

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

# Detect provider CLI (provider loaded at top of file)
provider_detect_cli || exit 1

CURRENT_BRANCH=$(git branch --show-current)

# Check if already in a worktree
MAIN_WORKTREE=$(git rev-parse --show-toplevel)
IS_MAIN_WORKTREE=false
# Defensive check: grep can return 1 if no match, which would exit script with set -e
if git worktree list | grep -q "^$(git rev-parse --show-toplevel).*\[main\]" || [[ "$CURRENT_BRANCH" == "main" ]]; then
  IS_MAIN_WORKTREE=true
fi

# Smart worktree detection and navigation
# Try to find existing worktree by issue number or description
TASK_IDENTIFIER="${ISSUE_NUMBER:-$ISSUE_DESC}"
if [ -n "$TASK_IDENTIFIER" ]; then
  WORKTREE_INFO=$(find_worktree_for_task "$TASK_IDENTIFIER")

  if [ -n "$WORKTREE_INFO" ]; then
    # Found existing worktree - navigate there
    TARGET_WORKTREE=$(echo "$WORKTREE_INFO" | cut -d'|' -f1)
    TARGET_BRANCH=$(echo "$WORKTREE_INFO" | cut -d'|' -f2)

    print_success "Found existing worktree for issue #$ISSUE_NUMBER"
    print_status "Branch: $TARGET_BRANCH"
    print_status "Location: $TARGET_WORKTREE"
    echo ""
    print_status "Navigating to worktree..."

    # Re-execute script in target worktree, passing issue description to avoid losing it
    # Use cd in subshell and export vars separately to avoid command injection
    cd "$TARGET_WORKTREE" || exit 1
    export CONTINUE_ISSUE_NUM="$ISSUE_NUMBER"
    export CONTINUE_ISSUE_DESC="$ISSUE_DESC"
    if [ "$AUTO_MODE" = true ]; then
      exec "$SCRIPT_PATH" --auto
    else
      exec "$SCRIPT_PATH"
    fi
  fi
  # If not found, continue below to create new worktree
fi

# If we reach here without an issue number, we're continuing in current worktree
if [ -z "$ISSUE_NUMBER" ]; then
  print_header "🔄 Continuing in Current Worktree"

  # Check if we're on main/develop
  if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "develop" ]]; then
    print_error "Cannot work on $CURRENT_BRANCH branch"
    echo "Please provide an issue number or description"
    exit 1
  fi

  # Get issue info from environment variables (passed during navigation)
  if [ -n "${CONTINUE_ISSUE_NUM:-}" ]; then
    ISSUE_NUMBER="$CONTINUE_ISSUE_NUM"
    ISSUE_DESC="${CONTINUE_ISSUE_DESC:-Continue work on $CURRENT_BRANCH}"
  else
    # Fallback: use branch name as description
    ISSUE_DESC="Continue work on $CURRENT_BRANCH"
  fi

  BRANCH_NAME="$CURRENT_BRANCH"

  # Check for existing PR (do this for ALL continuation scenarios)
  # Check for both open and merged PRs
  PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --state all --json number,title,url,state --jq '.[0]' 2>/dev/null || echo "")
  if [ ! -z "$PR_JSON" ] && [ "$PR_JSON" != "null" ]; then
    PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
    PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
    PR_URL=$(echo "$PR_JSON" | jq -r '.url')
    PR_STATE=$(echo "$PR_JSON" | jq -r '.state')

    if [ "$PR_STATE" = "MERGED" ]; then
      print_success "✅ Work already completed!"
      echo "  PR #$PR_NUMBER: $PR_TITLE"
      echo "  Status: MERGED"
      echo "  URL: $PR_URL"
      echo ""
      print_info "Nothing to do - exiting"
      exit 0
    fi

    # PR exists but is it just a placeholder? Check for actual file changes.
    # Use triple-dot (merge-base diff) so advancing main doesn't false-positive.
    FILE_CHANGES=$(git diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')

    if [ "$FILE_CHANGES" -gt 0 ]; then
      # PR has real work - jump directly to PR workflow
      print_info "Issue #$ISSUE_NUMBER has $FILE_CHANGES file(s) changed — proceeding to review workflow"
      echo ""

      # Jump directly to PR workflow script - skip development phase
      if [ -f "$RITE_LIB_DIR/core/create-pr.sh" ]; then
        if [ "$AUTO_MODE" = true ]; then
          exec "$RITE_LIB_DIR/core/create-pr.sh" --auto
        else
          exec "$RITE_LIB_DIR/core/create-pr.sh"
        fi
      else
        print_error "create-pr.sh not found"
        exit 1
      fi
    else
      # PR exists but only has placeholder commit - need to run development
      print_info "Issue #$ISSUE_NUMBER has a PR but no implementation yet"
      print_status "Running development phase..."
      echo ""
    fi
  else
    print_info "No PR exists yet for this branch"
  fi

else
  # Create new branch or use existing branch that was found
  if [ -z "${BRANCH_NAME:-}" ]; then
    # No existing branch found - create new branch name
    if [ -z "$ISSUE_DESC" ]; then
      print_error "Usage: rite <issue-number>"
      echo "   or: rite \"issue description\""
      exit 1
    fi

    # Sanitize branch name — use NORMALIZED_SUBJECT if available, strip type prefix first
    _branch_source="${NORMALIZED_SUBJECT:-$ISSUE_DESC}"
    # Strip conventional commit prefix (e.g., "fix: " or "feat(auth): ") before sanitizing — branch gets PREFIX/ from detection logic
    _branch_source=$(echo "$_branch_source" | sed -E 's/^[a-z]+(\([^)]*\))?: //')
    SANITIZED_DESC=$(echo "$_branch_source" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | cut -c1-50)

    # Validate sanitized result
    if [ -z "$SANITIZED_DESC" ] || [ ${#SANITIZED_DESC} -lt 3 ]; then
      print_error "Invalid issue description - must contain at least 3 alphanumeric characters"
      echo "Description: \"$ISSUE_DESC\""
      echo "After sanitization: \"$SANITIZED_DESC\""
      exit 1
    fi

    # Smart prefix detection
    PREFIX="feat"
    if echo "$ISSUE_DESC" | grep -iqE '(fix|bug|issue|error)'; then
      PREFIX="fix"
    elif echo "$ISSUE_DESC" | grep -iqE '(docs|documentation|readme)'; then
      PREFIX="docs"
    elif echo "$ISSUE_DESC" | grep -iqE '(test|testing|spec)'; then
      PREFIX="test"
    elif echo "$ISSUE_DESC" | grep -iqE '(refactor|cleanup|improve)'; then
      PREFIX="refactor"
    elif echo "$ISSUE_DESC" | grep -iqE '(chore|setup|config)'; then
      PREFIX="chore"
    fi

    BRANCH_NAME="${PREFIX}/${SANITIZED_DESC}"
  fi
  # else: BRANCH_NAME already set from existing branch detection

  # Check if this branch already has a worktree before trying to create one
  EXISTING_WT_FOR_BRANCH=$(git worktree list | grep "\[$BRANCH_NAME\]" | awk '{print $1}' || echo "")
  if [ -n "$EXISTING_WT_FOR_BRANCH" ]; then
    print_success "Found existing worktree for branch $BRANCH_NAME"
    print_info "Location: $EXISTING_WT_FOR_BRANCH"
    echo ""

    # Check for uncommitted changes in the target worktree before navigating
    TARGET_UNCOMMITTED=$(git -C "$EXISTING_WT_FOR_BRANCH" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$TARGET_UNCOMMITTED" -gt 0 ]; then
      print_warning "Uncommitted changes detected in target worktree"

      # Get diff of uncommitted changes
      UNCOMMITTED_DIFF=$(git -C "$EXISTING_WT_FOR_BRANCH" diff HEAD 2>/dev/null || echo "")
      UNCOMMITTED_FILES=$(git -C "$EXISTING_WT_FOR_BRANCH" status --short 2>/dev/null || echo "")

      # Use Claude CLI to analyze if changes are relevant to the issue
      print_status "Analyzing if changes are relevant to issue #$ISSUE_NUMBER..."

      ANALYSIS_PROMPT="Issue #$ISSUE_NUMBER: $ISSUE_DESC

Uncommitted changes in worktree:
$UNCOMMITTED_FILES

Diff:
$UNCOMMITTED_DIFF

Are these changes relevant to the issue? Answer with just 'RELEVANT' or 'UNRELATED'.
If the changes are implementing or fixing something described in the issue, answer RELEVANT.
If the changes are unrelated work, answer UNRELATED."

      RELEVANCE=$(provider_run_classify "$ANALYSIS_PROMPT" | grep -oE "(RELEVANT|UNRELATED)" | head -1 || echo "UNKNOWN")

      if [ "$RELEVANCE" = "RELEVANT" ]; then
        # Changes are relevant - commit them
        print_success "Changes are relevant to issue #$ISSUE_NUMBER - committing..."

        cd "$EXISTING_WT_FOR_BRANCH" || exit 1
        git add -A
        COMMIT_MSG="wip: auto-commit relevant changes for issue #$ISSUE_NUMBER ($(date +%Y-%m-%d))"

        if git commit -m "$COMMIT_MSG" 2>/dev/null; then
          print_success "Changes committed: $COMMIT_MSG"
          cd - > /dev/null || exit 1
        else
          print_error "Failed to commit changes"
          cd - > /dev/null || exit 1
          print_warning "Cannot navigate to worktree with uncommitted changes"
          exit 1
        fi
      elif [ "$RELEVANCE" = "UNRELATED" ]; then
        # Changes are unrelated - stash them
        print_status "Changes are unrelated to issue #$ISSUE_NUMBER - stashing..."

        cd "$EXISTING_WT_FOR_BRANCH" || exit 1
        STASH_MSG="Auto-stash unrelated changes before issue #$ISSUE_NUMBER ($(date +%Y-%m-%d))"

        if git stash push -m "$STASH_MSG" 2>/dev/null; then
          print_success "Changes stashed: $STASH_MSG"
          print_status "Recover later with: git stash list"
          cd - > /dev/null || exit 1
        else
          print_error "Failed to stash changes"
          cd - > /dev/null || exit 1
          print_warning "Cannot navigate to worktree with uncommitted changes"
          exit 1
        fi
      else
        # Unknown - fail safe and ask user
        print_warning "Could not determine if changes are relevant"
        print_status "Uncommitted files:"
        echo "$UNCOMMITTED_FILES"
        echo ""
        print_error "Please commit or stash changes manually in: $EXISTING_WT_FOR_BRANCH"
        exit 1
      fi
    fi

    print_status "Navigating to existing worktree..."
    # Pass issue info via environment to avoid losing it
    # Use cd and export separately to avoid command injection
    cd "$EXISTING_WT_FOR_BRANCH" || exit 1
    export CONTINUE_ISSUE_NUM="$ISSUE_NUMBER"
    export CONTINUE_ISSUE_DESC="$ISSUE_DESC"
    if [ "$AUTO_MODE" = true ]; then
      exec "$SCRIPT_PATH" --auto
    else
      exec "$SCRIPT_PATH"
    fi
  fi

  print_header "🌿 Creating New Worktree"
  echo "Branch: $BRANCH_NAME"
  echo "Mode: Git Worktree (mandatory for isolation)"
  echo ""

  # Worktree mode: Create isolated working directory (MANDATORY)
  # RITE_WORKTREE_DIR set by config.sh

  # Sanitize branch name to prevent path traversal
  # Remove: . (dot), .. (parent dir), leading/trailing slashes, multiple consecutive slashes
  SAFE_BRANCH_NAME="${BRANCH_NAME//\//-}"      # Replace / with -
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME//../-}" # Replace .. with -
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME//./}"   # Remove single dots
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME#-}"     # Remove leading dash
  SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME%-}"     # Remove trailing dash

  # Abbreviate prefix for shorter folder names: feat- → ft-, fix- → fx-, etc.
  SAFE_BRANCH_NAME=$(echo "$SAFE_BRANCH_NAME" | sed -E '
    s/^feat-/ft-/; s/^fix-/fx-/; s/^refactor-/rf-/;
    s/^docs-/dc-/; s/^test-/ts-/; s/^chore-/ch-/'
  )
  # Truncate at word boundary, max 35 chars
  if [ ${#SAFE_BRANCH_NAME} -gt 35 ]; then
    SAFE_BRANCH_NAME=$(echo "${SAFE_BRANCH_NAME:0:35}" | sed 's/-[^-]*$//')
  fi

  # In batch mode, append batch context to worktree name for identification
  if [ "${BATCH_MODE:-false}" = true ] && [ -n "${BATCH_ISSUE_LIST:-}" ]; then
    BATCH_SUFFIX="_b$(echo "$BATCH_ISSUE_LIST" | tr ' ' '-')"
    # Keep total path reasonable: truncate suffix if too long
    if [ ${#BATCH_SUFFIX} -gt 20 ]; then
      BATCH_SUFFIX="_b$(echo "$BATCH_ISSUE_LIST" | tr ' ' '-' | cut -c1-19)"
    fi
    SAFE_BRANCH_NAME="${SAFE_BRANCH_NAME}${BATCH_SUFFIX}"
  fi

  WORKTREE_PATH="$RITE_WORKTREE_DIR/$SAFE_BRANCH_NAME"

    # Create worktrees directory if it doesn't exist
    mkdir -p "$RITE_WORKTREE_DIR"

    # Count existing worktrees for limit check
    EXISTING_WORKTREES=$(git worktree list --porcelain | grep -E "^worktree $RITE_WORKTREE_DIR" | sed 's/^worktree //' || echo "")
    WORKTREE_COUNT=0
    MAX_WORKTREES=5

    if [ -n "$EXISTING_WORKTREES" ]; then
      while IFS= read -r wt_path; do
        [ -z "$wt_path" ] && continue
        WORKTREE_COUNT=$((WORKTREE_COUNT + 1))
      done <<< "$EXISTING_WORKTREES"

      # Check if at limit
      if [ "$WORKTREE_COUNT" -ge "$MAX_WORKTREES" ]; then
        print_warning "At worktree limit ($WORKTREE_COUNT/$MAX_WORKTREES)"
        print_status "Auto-cleanup: Looking for reusable worktrees..."

        # Find worktrees with:
        # 1. No uncommitted changes
        # 2. Branch already merged (check if exists on remote)
        # 3. Not currently in use

        CLEANED_COUNT=0
        while IFS= read -r wt_path; do
          [ -z "$wt_path" ] && continue

          WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")
          [ -z "$WT_BRANCH" ] && continue

          # Skip if has uncommitted changes
          UNCOMMITTED=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
          [ "$UNCOMMITTED" -gt 0 ] && continue

          # Check if branch is merged (not on remote anymore)
          if ! git ls-remote --heads origin "$WT_BRANCH" | grep -q "$WT_BRANCH" 2>/dev/null; then
            print_status "Cleaning merged worktree: $WT_BRANCH"
            git worktree remove "$wt_path" 2>/dev/null || true
            git branch -d "$WT_BRANCH" 2>/dev/null || true
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            [ "$CLEANED_COUNT" -ge 1 ] && break  # Only need to clean one to make room
          fi
        done <<< "$EXISTING_WORKTREES"

        if [ "$CLEANED_COUNT" -gt 0 ]; then
          print_success "Cleaned $CLEANED_COUNT worktree(s) - proceeding"
          WORKTREE_COUNT=$((WORKTREE_COUNT - CLEANED_COUNT))
        else
          # No clean worktrees found - look for oldest stale one
          print_status "No merged branches found - checking for stale worktrees..."

          OLDEST_WORKTREE=""
          OLDEST_AGE=0
          PROTECTED_COUNT=0

          while IFS= read -r wt_path; do
            [ -z "$wt_path" ] && continue

            WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")
            [ -z "$WT_BRANCH" ] && continue

            # Hard guard 1: skip if has uncommitted changes
            UNCOMMITTED=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [ "$UNCOMMITTED" -gt 0 ]; then
              PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
              continue
            fi

            # Hard guard 2: skip if branch has an OPEN PR — work is in flight even if working tree is clean.
            # A worktree with commits ahead + 0 uncommitted + open PR is NOT eligible for cleanup;
            # deleting it strands the user's review work mid-flow.
            OPEN_PR_COUNT=$(gh pr list --head "$WT_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo "0")
            if [ "$OPEN_PR_COUNT" -gt 0 ]; then
              PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
              continue
            fi

            # Hard guard 3: skip if local commits are ahead of remote (unpushed work).
            if git -C "$wt_path" rev-parse --verify "origin/$WT_BRANCH" >/dev/null 2>&1; then
              UNPUSHED=$(git -C "$wt_path" rev-list --count "origin/$WT_BRANCH..HEAD" 2>/dev/null || echo "0")
            else
              UNPUSHED=$(git -C "$wt_path" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
            fi
            if [ "$UNPUSHED" -gt 0 ]; then
              PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
              continue
            fi

            # Get last modification time
            LAST_MODIFIED=$(find "$wt_path" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.sh" \) 2>/dev/null | xargs stat -f "%m" 2>/dev/null | sort -rn | head -1 || echo "0")
            AGE=$(( $(date +%s) - LAST_MODIFIED ))

            if [ "$AGE" -gt "$OLDEST_AGE" ]; then
              OLDEST_AGE=$AGE
              OLDEST_WORKTREE="$wt_path"
              OLDEST_BRANCH="$WT_BRANCH"
            fi
          done <<< "$EXISTING_WORKTREES"

          if [ -n "$OLDEST_WORKTREE" ] && [ "$OLDEST_AGE" -gt 86400 ]; then  # > 1 day old
            DAYS_OLD=$((OLDEST_AGE / 86400))
            print_status "Removing stale worktree: $OLDEST_BRANCH (${DAYS_OLD} days old, no PR, no unpushed work)"
            git worktree remove "$OLDEST_WORKTREE" 2>/dev/null || true
            git branch -d "$OLDEST_BRANCH" 2>/dev/null || true
            print_success "Removed stale worktree - will create new one for issue #$ISSUE_NUMBER"
          elif [ -n "$OLDEST_WORKTREE" ]; then
            # Has worktrees but all are recent (< 1 day) - still remove oldest if eligible
            HOURS_OLD=$((OLDEST_AGE / 3600))
            print_warning "All worktrees are recent (oldest: ${HOURS_OLD}h)"
            print_status "Removing oldest eligible worktree: $OLDEST_BRANCH (no PR, no unpushed work)"
            git worktree remove "$OLDEST_WORKTREE" 2>/dev/null || true
            git branch -d "$OLDEST_BRANCH" 2>/dev/null || true
            print_success "Removed worktree - will create new one for issue #$ISSUE_NUMBER"
          else
            # All worktrees are protected (open PR, unpushed commits, or uncommitted changes).
            # Refuse to silently delete in-flight work — exceed the limit with a clear warning
            # and surface the protected list so the user can act intentionally.
            print_warning "All $WORKTREE_COUNT worktree(s) are protected from cleanup ($PROTECTED_COUNT protected: open PR, unpushed commits, or uncommitted changes)"
            print_warning "Exceeding limit of $MAX_WORKTREES — creating worktree #$((WORKTREE_COUNT + 1))"
            echo ""
            print_info "Protected worktrees (cannot be auto-cleaned):"
            while IFS= read -r wt_path; do
              [ -z "$wt_path" ] && continue
              WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "?")
              REASONS=""
              UNCOM=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
              [ "$UNCOM" -gt 0 ] && REASONS="${REASONS}uncommitted, "
              PR_N=$(gh pr list --head "$WT_BRANCH" --state open --json number --jq '.[0].number // ""' 2>/dev/null || echo "")
              [ -n "$PR_N" ] && REASONS="${REASONS}PR #$PR_N, "
              if git -C "$wt_path" rev-parse --verify "origin/$WT_BRANCH" >/dev/null 2>&1; then
                UNP=$(git -C "$wt_path" rev-list --count "origin/$WT_BRANCH..HEAD" 2>/dev/null || echo "0")
              else
                UNP=$(git -C "$wt_path" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
              fi
              [ "$UNP" -gt 0 ] && REASONS="${REASONS}${UNP} unpushed commit(s), "
              REASONS="${REASONS%, }"
              [ -z "$REASONS" ] && REASONS="(unknown — please report)"
              echo "   • $WT_BRANCH — $REASONS"
            done <<< "$EXISTING_WORKTREES"
            echo ""
            print_info "Tip: 'rite N' on a protected issue to resume + merge it, freeing the slot."
          fi
        fi
      fi
    else
      print_success "No existing worktrees found"
    fi

    echo ""

    # Fetch latest main so new branches start from current remote state
    # Critical for batch mode: after issue N merges, issue N+1 must branch from updated main
    print_status "Fetching latest origin/main..."
    git fetch origin main 2>/dev/null || print_warning "Failed to fetch origin/main - using local state"

    print_status "Creating worktree at: $WORKTREE_PATH"

    # Check if branch already exists
    if git show-ref --verify --quiet refs/heads/"$BRANCH_NAME"; then
      print_warning "Branch already exists"

      if [ "$AUTO_MODE" = false ]; then
        read -p "Create worktree for existing branch? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          print_error "Cancelled"
          exit 1
        fi
      else
        print_info "Using existing branch (auto mode)"
      fi

      # Try to add worktree - git will error if it already exists (handles TOCTOU race)
      if ! git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1; then
        # Worktree directory exists — verify it's on the expected branch.
        # A previous run may have left the worktree on a different branch
        # (e.g., fell back to main after empty-branch cleanup).
        if [ -d "$WORKTREE_PATH" ]; then
          ACTUAL_BRANCH=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
          if [ "$ACTUAL_BRANCH" = "$BRANCH_NAME" ]; then
            print_info "Worktree already exists on correct branch - using it"
          else
            print_warning "Worktree exists but on wrong branch ($ACTUAL_BRANCH), expected $BRANCH_NAME"
            print_status "Removing stale worktree and recreating..."
            git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || rm -rf "$WORKTREE_PATH"
            git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1 || {
              print_error "Failed to recreate worktree"
              exit 1
            }
          fi
        else
          print_error "Failed to create worktree"
          exit 1
        fi
      fi
    else
      # Create new branch in worktree from origin/main - git handles race condition
      if ! git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" origin/main >/dev/null 2>&1; then
        # Worktree directory exists — verify it's on the expected branch.
        if [ -d "$WORKTREE_PATH" ]; then
          ACTUAL_BRANCH=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
          if [ "$ACTUAL_BRANCH" = "$BRANCH_NAME" ]; then
            print_info "Worktree already exists on correct branch - using it"
          else
            print_warning "Worktree exists but on wrong branch ($ACTUAL_BRANCH), expected $BRANCH_NAME"
            print_status "Removing stale worktree and recreating..."
            git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || rm -rf "$WORKTREE_PATH"
            # Branch may already exist from a previous run — use it if so, otherwise create
            if git show-ref --verify --quiet refs/heads/"$BRANCH_NAME"; then
              git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1 || {
                print_error "Failed to recreate worktree (existing branch)"
                exit 1
              }
            else
              git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" origin/main >/dev/null 2>&1 || {
                print_error "Failed to recreate worktree (new branch)"
                exit 1
              }
            fi
          fi
        else
          print_error "Failed to create worktree and branch"
          exit 1
        fi
      fi
    fi

    print_success "Worktree ready"

    # Add symlink patterns to .gitignore BEFORE creating symlinks
    # This prevents them from ever appearing as untracked files in git status
    ensure_symlinks_gitignored() {
      local gitignore="$WORKTREE_PATH/.gitignore"
      # No trailing slashes — "foo/" only matches directories, but symlinks are
      # files (mode 120000) so "foo/" won't match them. "foo" matches both.
      local patterns=(".rite" ".claude" "node_modules" "backend/node_modules")
      local updated=0

      for pattern in "${patterns[@]}"; do
        # Already has the correct (no-slash) entry — nothing to do
        if [ -f "$gitignore" ] && grep -qxF "$pattern" "$gitignore" 2>/dev/null; then
          continue
        fi
        # Has the old trailing-slash form that doesn't match symlinks — upgrade it
        if [ -f "$gitignore" ] && grep -qxF "${pattern}/" "$gitignore" 2>/dev/null; then
          # Platform-specific sed -i syntax
          if sed --version >/dev/null 2>&1; then
            # GNU sed
            sed -i "s|^${pattern}/$|${pattern}|" "$gitignore"
          else
            # BSD sed (macOS)
            sed -i '' "s|^${pattern}/$|${pattern}|" "$gitignore"
          fi
          ((updated++)) || true
          continue
        fi
        echo "$pattern" >> "$gitignore"
        ((updated++)) || true
      done

      if [ "$updated" -gt 0 ]; then
        print_info "Updated $updated symlink pattern(s) in .gitignore"
      fi
    }
    ensure_symlinks_gitignored

    # Symlink node_modules to save disk space (if project has them)
    if [ -d "$MAIN_WORKTREE/node_modules" ]; then
      cd "$WORKTREE_PATH"
      rm -rf node_modules 2>/dev/null || true
      ln -s "$MAIN_WORKTREE/node_modules" node_modules
      cd "$WORKTREE_PATH"
    elif [ -d "$MAIN_WORKTREE/backend/node_modules" ]; then
      cd "$WORKTREE_PATH/backend" 2>/dev/null || true
      rm -rf node_modules 2>/dev/null || true
      ln -s "$MAIN_WORKTREE/backend/node_modules" node_modules 2>/dev/null || true
      cd "$WORKTREE_PATH"
    fi

    # Symlink rite data dir to share scratchpad and context across worktrees
    RITE_DATA_PATH="$MAIN_WORKTREE/$RITE_DATA_DIR"
    if [ -d "$RITE_DATA_PATH" ]; then
      print_status "Symlinking $RITE_DATA_DIR directory for shared scratchpad..."
      rm -rf "$WORKTREE_PATH/$RITE_DATA_DIR" 2>/dev/null || true
      ln -s "$RITE_DATA_PATH" "$WORKTREE_PATH/$RITE_DATA_DIR"
      print_success "Shared scratchpad linked"
    fi

    # Also symlink .claude/ if it exists (backward compat)
    if [ -d "$MAIN_WORKTREE/.claude" ]; then
      rm -rf "$WORKTREE_PATH/.claude" 2>/dev/null || true
      ln -s "$MAIN_WORKTREE/.claude" "$WORKTREE_PATH/.claude"
    fi

    # Switch to worktree directory
    cd "$WORKTREE_PATH"
    print_success "Switched to worktree: $WORKTREE_PATH"

    # Store worktree path for cleanup later
    export CLAUDE_WORKTREE_PATH="$WORKTREE_PATH"

    # Write handoff file so workflow-runner.sh can find this worktree even when
    # RITE_ORCHESTRATED=true (no PR created during dev, so PR-based detection fails).
    if [ -n "${RITE_STATE_DIR:-}" ] && [ -n "${ISSUE_NUMBER:-}" ]; then
      echo "$WORKTREE_PATH" > "${RITE_STATE_DIR}/worktree-handoff-${ISSUE_NUMBER}.txt" 2>/dev/null || true
    fi

    # Check for relevant stashed changes and auto-apply if they're from this branch
    LATEST_STASH_BRANCH=$(git stash list 2>/dev/null | head -1 | grep -oE 'WIP on [^:]+|On [^:]+' | sed 's/.*On //' | sed 's/WIP on //' || echo "")

    if [ -n "$LATEST_STASH_BRANCH" ] && [ "$LATEST_STASH_BRANCH" = "$BRANCH_NAME" ]; then
      # Most recent stash is from this branch - auto-apply
      print_status "Found recent stash from this branch - auto-applying..."
      if git stash pop 2>/dev/null; then
        print_success "Stash applied"
      else
        print_warning "Could not apply stash (may have conflicts)"
        print_info "Resolve manually with: git stash pop"
      fi
    fi
fi

# Ensure symlink patterns are present in .gitignore WITHOUT trailing slashes.
# "foo/" only matches directories, but symlinks are files (mode 120000).
# This runs on ALL paths (new worktree + continuation + fix iteration) to handle:
#   - Worktrees created from older commits missing patterns
#   - Patterns accidentally removed during Claude's development session
#   - Old trailing-slash forms that don't match symlinks
for _pattern in ".rite" ".claude" "node_modules" "backend/node_modules"; do
  # Already has the correct (no-slash) entry — nothing to do
  if [ -f .gitignore ] && grep -qxF "$_pattern" .gitignore 2>/dev/null; then
    continue
  fi
  # Has the old trailing-slash form — upgrade it
  if [ -f .gitignore ] && grep -qxF "${_pattern}/" .gitignore 2>/dev/null; then
    # Platform-specific sed -i syntax
    if sed --version >/dev/null 2>&1; then
      sed -i "s|^${_pattern}/$|${_pattern}|" .gitignore
    else
      sed -i '' "s|^${_pattern}/$|${_pattern}|" .gitignore
    fi
    continue
  fi
  # Pattern missing entirely — add it
  echo "$_pattern" >> .gitignore
done

# Defensive merge: ensure branch is up-to-date with origin/main before starting work
# Prevents merge conflicts at PR time, especially in batch mode where earlier issues
# merge to main while later issues are still working on stale branches.
# New branches (just created from origin/main) will show 0 behind — this is a no-op for them.
if [[ "$BRANCH_NAME" != "main" && "$BRANCH_NAME" != "develop" ]]; then
  git fetch origin main 2>/dev/null || true
  BEHIND_COUNT=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
  if [ "$BEHIND_COUNT" -gt 0 ]; then
    print_status "Branch is $BEHIND_COUNT commit(s) behind main — merging origin/main..."
    if git merge origin/main --no-edit 2>/dev/null; then
      # Verify merge didn't introduce silent semantic conflicts
      source "$RITE_LIB_DIR/utils/post-merge-verify.sh"
      if ! verify_post_merge "."; then
        print_warning "Merge with main introduced test failures — reverting merge"
        git reset --hard HEAD~1 2>/dev/null || true
        print_error "Silent semantic conflict: merge succeeds but tests fail ($BEHIND_COUNT commits behind)"
        print_info "Resolve manually: git merge origin/main, then fix failing tests"
        exit 1
      fi
      print_success "Merged origin/main into branch"
    else
      # Merge conflict — abort and fail fast rather than auto-resolving
      git merge --abort 2>/dev/null || true
      print_error "Merge conflict with main ($BEHIND_COUNT commits behind)"
      print_info "Resolve manually: git merge origin/main"
      exit 1
    fi
  fi
fi

# Check git status (filter .gitignore — modified by sharkrite's symlink pattern repair)
print_header "📊 Repository Status"
echo "📋 Issue: ${ISSUE_NUMBER:+#$ISSUE_NUMBER - }$ISSUE_DESC"
echo "   Branch: $BRANCH_NAME"
echo "   Location: $(pwd)"
echo ""
git status --short | grep -v "\.gitignore$" || true

# Count uncommitted changes (exclude untracked files and .gitignore)
# Only count modified (M), added (A), deleted (D), renamed (R), copied (C) files
# Exclude ?? (untracked) which includes symlinks
# Pattern: git status --porcelain shows " M file" for modified, "?? file" for untracked
UNCOMMITTED_CHANGES=$(git status --porcelain | { grep -vE "^\?\?" || true; } | { grep -v "\.gitignore$" || true; } | wc -l | tr -d ' ')
echo ""

if [ "$UNCOMMITTED_CHANGES" -gt 0 ]; then
  print_info "Found $UNCOMMITTED_CHANGES uncommitted changes"
  echo ""
  print_info "Work appears to be in progress - skipping Sharkrite session"
  print_info "Will proceed directly to commit/PR workflow"
  echo ""

  # Set flag to skip Sharkrite session
  SKIP_CLAUDE=true
else
  print_success "No uncommitted changes (untracked files will be ignored)"
  SKIP_CLAUDE=false
fi

# PR-First Approach: Create draft PR early for tracking
# This allows us to find worktrees by PR instead of branch name patterns
print_header "📋 Creating Draft PR for Tracking"

# Check if PR already exists for this branch
EXISTING_PR=$(gh pr list --head "$BRANCH_NAME" --json number,title,url,isDraft --jq '.[0]' 2>/dev/null || echo "{}")

if [ "$EXISTING_PR" != "{}" ] && [ -n "$EXISTING_PR" ]; then
  PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number')
  PR_TITLE=$(echo "$EXISTING_PR" | jq -r '.title')
  IS_DRAFT=$(echo "$EXISTING_PR" | jq -r '.isDraft')

  # PR exists - no message needed (workflow-runner already informed user)
  echo ""
else
  # Create empty commit for PR (will be amended later with real changes)
  # Check commits AHEAD of main only — a "chore: initialize work" on main itself
  # (from a merged PR) must not suppress creating a new init commit for this branch.
  if ! git log --oneline origin/main..HEAD 2>/dev/null | grep -q "chore: initialize work"; then
    commit_output=$(git commit --allow-empty -m "chore: initialize work on ${ISSUE_NUMBER:+#$ISSUE_NUMBER }${ISSUE_DESC}" 2>&1)
    # Format: [branch hash] message — show branch/hash on one line, message indented below
    branch_info=$(echo "$commit_output" | head -1 | sed 's/] .*/]/')
    commit_msg=$(echo "$commit_output" | head -1 | sed 's/^[^]]*] //')
    echo "$branch_info"
    echo "	$commit_msg"
  fi

  # Push to create remote branch
  if push_output=$(git push -u origin "$BRANCH_NAME" 2>&1); then
    # Format: split "set up to track" onto its own line
    echo "$push_output" | while IFS= read -r line; do
      if [[ "$line" == *"set up to track"* ]]; then
        echo "$line" | sed "s/ set up to track /\n	set up to track /"
      fi
    done
  else
    # Non-fast-forward: remote branch diverged (e.g., undo reset it to main).
    # Force push instead of delete+recreate — delete closes any linked PR.
    print_warning "Remote branch diverged — force pushing to sync"
    git fetch origin "$BRANCH_NAME" 2>/dev/null || true
    git push -u --force-with-lease origin "$BRANCH_NAME" >/dev/null 2>&1 || \
      git push -u --force origin "$BRANCH_NAME" >/dev/null 2>&1 || true
  fi

  # Create draft PR
  PR_TITLE="${NORMALIZED_SUBJECT:-$ISSUE_DESC}"
  PR_BODY="## Work in Progress

$(if [ -n "$ISSUE_NUMBER" ]; then echo "Closes #$ISSUE_NUMBER"; fi)

${WORK_DESCRIPTION:-This PR is being worked on. Implementation details will be updated as work progresses.}

---
_Draft PR created automatically by rite for tracking purposes._"

  print_status "Creating draft PR..."

  # Use temp file to avoid shell metacharacter issues in body
  DRAFT_BODY_FILE=$(mktemp)
  printf '%s' "$PR_BODY" > "$DRAFT_BODY_FILE"
  gh pr create \
    --draft \
    --base main \
    --head "$BRANCH_NAME" \
    --title "$PR_TITLE" \
    --body-file "$DRAFT_BODY_FILE" \
    2>/dev/null || print_warning "PR creation failed (may already exist)"
  rm -f "$DRAFT_BODY_FILE"

  # Get PR number
  PR_NUMBER=$(gh pr list --head "$BRANCH_NAME" --json number --jq '.[0].number' 2>/dev/null)

  if [ -n "$PR_NUMBER" ]; then
    print_success "Draft PR #$PR_NUMBER created"
    echo ""
  else
    print_warning "Could not get PR number - continuing without PR link"
    echo ""
  fi
fi

# Build Claude Code prompt
print_header "🦈 Starting Sharkrite Session"

# Show model info — derive friendly name from model ID
# claude-sonnet-4-5-20250929 → Claude Sonnet 4.5
# claude-opus-4-6 → Claude Opus 4.6
_model_base="${RITE_CLAUDE_MODEL#claude-}"
_model_base="${_model_base%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
_model_name="${_model_base%%-[0-9]*}"
_model_ver="${_model_base#"$_model_name"-}"
_model_ver="${_model_ver//-/.}"
_model_name="$(echo "${_model_name:0:1}" | tr '[:lower:]' '[:upper:]')${_model_name:1}"
echo "⚡ Powered by Claude $_model_name $_model_ver"
echo ""

# Read scratchpad security findings if available
SECURITY_CONTEXT=""
# SCRATCHPAD_FILE set by config.sh

if [ -f "$SCRATCHPAD_FILE" ]; then
  print_status "Loading recent security findings from scratchpad..."

  # Extract "Recent Security Findings" section
  SECURITY_CONTEXT=$(sed -n '/## Recent Security Findings/,/## /p' "$SCRATCHPAD_FILE" | sed '1d;$d' || echo "")

  if [ -n "$SECURITY_CONTEXT" ]; then
    print_success "Loaded security context from last 5 PRs"
  fi

  # Update "Current Work" section
  TEMP_SCRATCH=$(mktemp)
  if grep -q "## Current Work" "$SCRATCHPAD_FILE"; then
    # Update existing section
    sed "/## Current Work/,/^## /{//!d;}" "$SCRATCHPAD_FILE" > "$TEMP_SCRATCH"
    # Platform-specific sed -i syntax
    if sed --version >/dev/null 2>&1; then
      # GNU sed
      sed -i "/## Current Work/a\\
\\
**Issue:** #${ISSUE_NUMBER:-unknown}\\
**Description:** ${ISSUE_DESC}\\
**Branch:** ${BRANCH_NAME:-$CURRENT_BRANCH}\\
**Started:** $(date '+%Y-%m-%d %H:%M:%S')\\
" "$TEMP_SCRATCH"
    else
      # BSD sed (macOS)
      sed -i '' "/## Current Work/a\\
\\
**Issue:** #${ISSUE_NUMBER:-unknown}\\
**Description:** ${ISSUE_DESC}\\
**Branch:** ${BRANCH_NAME:-$CURRENT_BRANCH}\\
**Started:** $(date '+%Y-%m-%d %H:%M:%S')\\
" "$TEMP_SCRATCH"
    fi
    mv "$TEMP_SCRATCH" "$SCRATCHPAD_FILE"
  else
    # Add section if missing
    echo -e "\n## Current Work\n\n**Issue:** #${ISSUE_NUMBER:-unknown}\n**Description:** ${ISSUE_DESC}\n**Branch:** ${BRANCH_NAME:-$CURRENT_BRANCH}\n**Started:** $(date '+%Y-%m-%d %H:%M:%S')\n" >> "$SCRATCHPAD_FILE"
  fi
fi

SECURITY_PROMPT=""
if [ -n "$SECURITY_CONTEXT" ]; then
  SECURITY_PROMPT="

## ⚠️ Recent Security Findings (Last 5 PRs)

**IMPORTANT:** Review these security issues found in recent PRs. Avoid repeating these patterns:

$SECURITY_CONTEXT

---
"
fi

ENCOUNTERED_ISSUES_PROMPT="

## Encountered Issues Protocol

When you discover issues NOT in scope for this issue (test failures, security concerns, code smells, deprecations, missing docs):

1. Do NOT fix them (stay focused on current issue)
2. Do NOT block on them (proceed with your work)
3. DO log them to the scratchpad under \"## Encountered Issues (Needs Triage)\":

Format:
- **YYYY-MM-DD** | \`file:line\` | category | Brief description | Affects: [feature/behavior] | Fix: [intended fix] | Done: [acceptance criteria]

Categories: test-failure, security, code-smell, missing-docs, deprecation, performance

Example:
- **2026-02-10** | \`response.test.ts:45\` | test-failure | CORS header assertion expects 'X-Content-Type-Options' | Affects: API security headers compliance | Fix: Add X-Content-Type-Options to CORS_HEADERS constant in response.ts | Done: All response.test.ts CORS tests pass

This creates visibility without scope creep. Issues will be triaged into tech-debt tickets at merge time.
"

if [ "$AUTO_MODE" = true ]; then
  PHASE_0_INSTRUCTIONS="**AUTO MODE: Make reasonable assumptions and proceed without stopping for clarification.**

1. Review the task description: \"${ISSUE_DESC}\"
2. Make sensible defaults based on:
   - Existing patterns in the codebase
   - Industry best practices (e.g., OWASP recommendations for security)
   - Standard configurations for the technology stack
3. **Skip clarification questions and proceed directly to Phase 1**
4. Document your assumptions in the implementation"
else
  PHASE_0_INSTRUCTIONS="1. Review the task description: \"${ISSUE_DESC}\"
2. Determine if clarification is needed based on:
   - Is the scope clear?
   - Does this follow existing patterns in the codebase?
   - Are there ambiguous requirements?
3. **Skip this phase** for straightforward tasks like:
   - Simple bug fixes (\"fix typo in README\")
   - Clear updates (\"add logging to auth-service\")
   - Configuration changes (\"update test timeout to 30s\")
4. **Ask focused questions** for complex/ambiguous tasks:
   - \"add OAuth integration\" → Which provider? Which flows?
   - \"improve rate limiting\" → What's the problem? New limits?
   - \"add health check endpoint\" → What should it check? Auth required?
5. Wait for answers before proceeding to Phase 1"
fi


# Set auto mode instructions
if [ "$AUTO_MODE" = true ]; then
  AUTO_MODE_INSTRUCTION="Proceed directly to implementation (auto mode - no approval needed)"
else
  AUTO_MODE_INSTRUCTION="Proceed directly to implementation (supervised mode - approval prompts are handled by the rite workflow, not by pausing here)"
fi

# Build prompt: provider-specific preamble + generic workflow instructions
_PROVIDER_PREAMBLE=$(provider_dev_session_preamble "$AUTO_MODE" "${WORK_DESCRIPTION:-$ISSUE_DESC}")
_PROVIDER_EXIT_NOTE=$(provider_exit_instructions "$AUTO_MODE")

CLAUDE_PROMPT="${_PROVIDER_PREAMBLE}
${SECURITY_PROMPT}${ENCOUNTERED_ISSUES_PROMPT}
## Workflow Instructions

Please follow this structured workflow:

### Phase 0: Requirements Clarification
${PHASE_0_INSTRUCTIONS}

### Phase 1: Analysis
1. **FIRST: Check if work is already complete** — but be precise:
   - Verify acceptance criteria against the **specific domain/feature** the issue targets, not similar patterns elsewhere
   - If the issue references a parent PR (e.g., \"From PR #N\"), check what domain/files that PR touched — your verification must cover that same domain
   - Finding similar tests or code in **other** domains does NOT mean this issue is done — each domain needs its own coverage
   - Only conclude \"already complete\" if every acceptance criterion is met for the exact scope described
2. If work is genuinely complete:
   - Report your findings with evidence (file paths, test results, etc.)
   - Check if a PR exists for this issue (use: gh pr list --search \"<issue-title>\" --state all)
   - **If PR exists on different branch:**
     - Inform user: Work already merged/in-review on another branch
     - Close this branch and worktree (duplicate work)
     - Close the issue if PR is merged
     - **STOP - cleanup complete**
   - **If no PR exists:**
     - Inform user: Work is complete but not in a PR yet
     - Skip to Phase 4 (Testing) to verify everything works
     - Then continue to PR creation and full workflow
     - **DO NOT skip the workflow - this branch has the completed work**
3. If work is incomplete, continue with analysis:
   - Read relevant files to understand the codebase
   - **If a Files to Read entry doesn't exist:**
     - Check whether a listed dependency (After: #N / Blocked by: #N) accounts for its creation
     - If yes: note the absence and continue — do NOT create or stub it out
     - If no dependency covers it: log it to the scratchpad as an encountered issue (category: \`missing-dependency\`, description: what file is missing and why it matters), then continue without creating it
   - Search for related patterns and existing implementations
   - Review project documentation (CLAUDE.md, docs/Technical-Specs.md)
   - **CRITICAL: For security-sensitive code**, consult docs/security/DEVELOPMENT-GUIDE.md
   - Identify dependencies and integration points

### Phase 2: Planning
1. Explain your proposed implementation approach
2. List all files you'll create or modify
3. Identify potential issues or trade-offs
4. ${AUTO_MODE_INSTRUCTION}

### Phase 3: Implementation
1. Implement the solution following best practices
2. Follow existing code patterns and conventions
3. Add proper error handling
4. Include comments for complex logic
5. Ensure multi-tenant isolation if applicable

### Phase 4: Testing & Validation
1. Write or update unit tests for the code you changed
2. Verify your new code imports/compiles without errors (quick syntax check)
3. Do NOT run the full test suite — the rite workflow runs it automatically after this session with parallel execution. Running it here wastes time.

### Phase 5: Code Comments
1. Add inline comments and JSDoc/TSDoc for complex logic only
2. Do NOT update files in docs/, README, or CHANGELOG — those are handled by a separate review phase

**Remember**: Update your todo list as you complete each phase. Mark the current phase as 'in_progress' and completed phases as 'completed'.

${_PROVIDER_EXIT_NOTE}

Begin with Phase 0: Requirements Clarification."

echo "Starting Sharkrite with task:"
echo "\"$ISSUE_DESC\""
echo ""

# Detect if already running in Claude Code
ALREADY_IN_CLAUDE=false
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_SESSION:-}" ] || ps aux | grep -v grep | grep -q "claude-code"; then
  ALREADY_IN_CLAUDE=true
fi

# Run Claude Code (unless skipped)
if [ "$SKIP_CLAUDE" = true ]; then
  print_info "Skipping Sharkrite session (work already in progress)"
  print_info "Proceeding to post-workflow"
  echo ""
elif [ "$ALREADY_IN_CLAUDE" = true ]; then
  print_warning "Already running inside Sharkrite - skipping recursive invocation"
  print_info "Sharkrite work complete - proceeding to post-workflow"
  echo ""
else
  # Set timeout for Claude Code (configurable via RITE_CLAUDE_TIMEOUT, default 2 hours)
  CLAUDE_TIMEOUT=${RITE_CLAUDE_TIMEOUT:-7200}
  _timer_start "claude_dev_session"
  print_status "Launching Sharkrite (timeout: ${CLAUDE_TIMEOUT}s)..."

  # Both modes run in FOREGROUND for streaming output
  CLAUDE_EXIT_CODE=0

  # Safety gate: provider must support tool restrictions for unsupervised mode
  if [ "$AUTO_MODE" = true ] && ! provider_supports_tool_restrictions; then
    print_error "Provider '$(provider_name)' does not support tool restrictions"
    print_error "Unsupervised dev sessions require tool restriction support"
    print_info "Use --supervised mode, or set RITE_DEV_PROVIDER=claude"
    exit 1
  fi

  # Capture provider stderr for diagnostics
  CLAUDE_STDERR_FILE=$(mktemp)

  provider_run_agentic_session "$CLAUDE_PROMPT" "$CLAUDE_TIMEOUT" "$AUTO_MODE" "$CLAUDE_STDERR_FILE"
  CLAUDE_EXIT_CODE=$?

  # Handle exit codes
  if [ $CLAUDE_EXIT_CODE -eq 124 ]; then
    # Timeout
    print_error "Sharkrite timed out after ${CLAUDE_TIMEOUT}s"
    print_status "Checking for uncommitted work..."

    if [ "$(git status --porcelain | { grep -v "\.gitignore$" || true; } | wc -l | tr -d ' ')" -gt 0 ]; then
      print_warning "Found uncommitted changes - committing before exit"
      # Fall through to post-workflow to commit changes
    else
      print_error "No changes detected - workflow failed"
      exit 1
    fi
  elif [ $CLAUDE_EXIT_CODE -eq 127 ]; then
    # Command not found - this is a setup error, not recoverable
    print_error "Command not found (exit code 127)"
    print_error "This usually means a required tool is missing."
    print_info "Check that the '$(provider_name)' CLI is installed"
    exit 127
  elif [ $CLAUDE_EXIT_CODE -ne 0 ]; then
    print_error "Sharkrite exited with error code $CLAUDE_EXIT_CODE"
    if [ -f "${CLAUDE_STDERR_FILE:-}" ] && [ -s "${CLAUDE_STDERR_FILE:-}" ]; then
      echo "Provider stderr:"
      cat "$CLAUDE_STDERR_FILE"
    fi
    print_status "Checking for uncommitted work..."

    if [ "$(git status --porcelain | { grep -v "\.gitignore$" || true; } | wc -l | tr -d ' ')" -gt 0 ]; then
      print_warning "Found uncommitted changes - will attempt to save work"
      # Fall through to post-workflow to commit changes
    else
      exit 1
    fi
  fi

  _timer_end "claude_dev_session"

  # Diagnostic output (visible in log, helps debug "no work" situations)
  if [ -n "${RITE_LOG_FILE:-}" ]; then
    echo ""
    _session_mode="dev"
    [ "${FIX_REVIEW_MODE:-false}" = true ] && _session_mode="fix-review"
    _diag "SESSION issue=${ISSUE_NUMBER:-?} mode=${_session_mode} provider=$(provider_name) exit=${CLAUDE_EXIT_CODE}"
    echo "[DIAG] Provider session exit code: $CLAUDE_EXIT_CODE"
    echo "[DIAG] Working directory: $(pwd)"
    echo "[DIAG] Git status (porcelain):"
    git status --porcelain 2>/dev/null | head -20 || echo "  (none)"
    echo "[DIAG] File changes vs origin/main:"
    git diff --stat origin/main...HEAD 2>/dev/null || echo "  (none)"
    if [ -f "$CLAUDE_STDERR_FILE" ] && [ -s "$CLAUDE_STDERR_FILE" ]; then
      echo "[DIAG] Provider stderr (last 30 lines):"
      tail -30 "$CLAUDE_STDERR_FILE" | sed 's/^/  /'
    else
      echo "[DIAG] Provider stderr: (empty)"
    fi
    echo ""
  fi
  rm -f "${CLAUDE_STDERR_FILE:-}" 2>/dev/null || true
fi

# Post-Claude workflow
if [ "${SKIP_TO_PR:-false}" = true ]; then
  # PR already exists, skip commit/push and go straight to PR workflow
  echo ""
else
  # Re-ensure symlink patterns in .gitignore after Claude's session.
  # Claude may have modified .gitignore during development, dropping patterns.
  for _pattern in ".rite" ".claude" "node_modules" "backend/node_modules"; do
    if [ -f .gitignore ] && grep -qxF "$_pattern" .gitignore 2>/dev/null; then
      continue
    fi
    if [ -f .gitignore ] && grep -qxF "${_pattern}/" .gitignore 2>/dev/null; then
      # Platform-specific sed -i syntax
      if sed --version >/dev/null 2>&1; then
        sed -i "s|^${_pattern}/$|${_pattern}|" .gitignore
      else
        sed -i '' "s|^${_pattern}/$|${_pattern}|" .gitignore
      fi
      continue
    fi
    echo "$_pattern" >> .gitignore
  done

  verbose_header "📝 Post-Implementation Workflow"
  verbose_echo "Sharkrite session complete. Let's review what changed."
  verbose_echo ""

  # Show changes (filter .gitignore — modified by sharkrite's symlink pattern repair)
  if is_verbose; then
    git status --short | grep -v "\.gitignore$" || true
  fi
  CHANGES_COUNT=$(git status --porcelain | { grep -v "\.gitignore$" || true; } | wc -l | tr -d ' ')

if [ $CHANGES_COUNT -eq 0 ]; then
  print_info "No new changes detected"
  echo ""

  # Check if there are any actual file changes (more reliable than commit message parsing).
  # Use triple-dot (merge-base diff) so advancing main doesn't false-positive.
  FILE_CHANGES=$(git diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')

  if [ "$FILE_CHANGES" -eq 0 ]; then
    # No work was done in the dev phase - exit early
    print_warning "No work was done in the development phase"
    echo ""
    print_info "This can happen if:"
    echo "  • The task was already complete"
    echo "  • Claude determined no changes were needed"
    echo "  • The session timed out before making changes"
    echo ""

    if [ "${RITE_ORCHESTRATED:-false}" = "true" ]; then
      # In orchestrated mode, let the orchestrator handle cleanup and retry.
      # Do NOT close the draft PR — workflow-runner owns the PR lifecycle.
      exit 4  # Distinct code: "session completed but no work produced"
    fi

    # Standalone mode: clean up the empty branch
    CURRENT_BRANCH=$(git branch --show-current)
    if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ]; then
      # Check if this is an empty branch we just created
      if git log --oneline origin/main..HEAD 2>/dev/null | grep -q "chore: initialize work"; then
        print_status "Cleaning up empty branch..."

        # Delete the draft PR if it exists
        DRAFT_PR=$(gh pr list --head "$CURRENT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
        if [ -n "$DRAFT_PR" ]; then
          gh pr close "$DRAFT_PR" --delete-branch 2>/dev/null || true
          print_info "Closed draft PR #$DRAFT_PR"
        fi
      fi
    fi

    exit 0
  fi

  print_info "Found $FILE_CHANGES file(s) changed - proceeding to PR workflow"
else
  print_success "$CHANGES_COUNT file(s) changed"
  echo ""

  # Show diff stats (.gitignore appears here but is excluded from the commit
  # at line ~1634 via git reset HEAD .gitignore — display is accurate to working tree)
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  git diff --stat
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Run test gate before commit (shared function handles auto/supervised + exit 3)
  run_test_gate

# Commit workflow
if [ "$AUTO_MODE" = false ]; then
  echo ""
  read -p "📝 Create commit? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Skipped commit. Run rite --continue to resume."
    exit 0
  fi
fi

# Smart commit message generation
if [ "$AUTO_MODE" = false ]; then
  print_status "Generating commit message..."
fi

# Build commit message — detect conventional commit prefix from title keywords,
# then prepend to the subject. NORMALIZED_SUBJECT is prefix-free (clean issue title).
COMMIT_TYPE="feat"
if [[ "$BRANCH_NAME" =~ ^(fix|feat|docs|test|refactor|chore)/ ]]; then
  COMMIT_TYPE=$(echo "$BRANCH_NAME" | cut -d'/' -f1)
fi

COMMIT_SOURCE="${NORMALIZED_SUBJECT:-$ISSUE_DESC}"
if echo "$COMMIT_SOURCE" | grep -qE "^(fix|feat|docs|test|refactor|chore|build|ci|perf|style)(\(.*\))?:"; then
  # Title already has a prefix (e.g., from older issues) — use as-is
  COMMIT_SUBJECT="$COMMIT_SOURCE"
else
  # Detect prefix from keywords if branch didn't provide one
  if [ "$COMMIT_TYPE" = "feat" ]; then
    if echo "$COMMIT_SOURCE" | grep -iqE '(fix|bug|issue|error)'; then
      COMMIT_TYPE="fix"
    elif echo "$COMMIT_SOURCE" | grep -iqE '(docs|documentation|readme)'; then
      COMMIT_TYPE="docs"
    elif echo "$COMMIT_SOURCE" | grep -iqE '(test|testing|spec)'; then
      COMMIT_TYPE="test"
    elif echo "$COMMIT_SOURCE" | grep -iqE '(refactor|cleanup|improve)'; then
      COMMIT_TYPE="refactor"
    elif echo "$COMMIT_SOURCE" | grep -iqE '(chore|setup|config)'; then
      COMMIT_TYPE="chore"
    fi
  fi
  COMMIT_SUBJECT="${COMMIT_TYPE}: ${COMMIT_SOURCE}"
fi

# Add body with changed files summary (before staging, so use working tree diff)
CHANGED_FILES=$(git status --porcelain | grep -vE "^\?\?" | grep -v "\.gitignore$" | sed 's/^...//' | sort 2>/dev/null || true)
COMMIT_BODY=""
if [ -n "$CHANGED_FILES" ]; then
  FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
  COMMIT_BODY="

Files changed (${FILE_COUNT}):
$(echo "$CHANGED_FILES" | sed 's/^/  - /')

${ISSUE_NUMBER:+Closes #$ISSUE_NUMBER}"
fi

COMMIT_MSG="${COMMIT_SUBJECT}${COMMIT_BODY}"

if [ "$AUTO_MODE" = false ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Suggested commit message:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$COMMIT_MSG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -p "Accept this message? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Enter custom commit message:"
    read -e CUSTOM_MSG
    if [ -z "$CUSTOM_MSG" ]; then
      print_info "Empty message — skipping commit. Changes preserved in worktree."
      exit 0
    fi
    COMMIT_MSG="$CUSTOM_MSG"
  fi
else
  verbose_info "Using auto-generated commit message: $COMMIT_MSG"
fi

# Create commit (use -A to respect .gitignore)
git add -A

# CRITICAL: Remove worktree-specific symlinks from staging
# These symlinks are created by the workflow but should NEVER be committed
if git ls-files --stage | grep -q '^120000.*\.claude$'; then
  git reset HEAD .claude 2>/dev/null || true
  print_warning "Removed .claude symlink from staging (worktree-specific)"
fi

if git ls-files --stage | grep -q "^120000.*${RITE_DATA_DIR}$"; then
  git reset HEAD "$RITE_DATA_DIR" 2>/dev/null || true
  print_warning "Removed $RITE_DATA_DIR symlink from staging (worktree-specific)"
fi

if git ls-files --stage | grep -q '^120000.*backend/node_modules$'; then
  git reset HEAD backend/node_modules 2>/dev/null || true
  print_warning "Removed backend/node_modules symlink from staging (worktree-specific)"
fi

if git ls-files --stage | grep -q '^120000.*node_modules$'; then
  git reset HEAD node_modules 2>/dev/null || true
  print_warning "Removed node_modules symlink from staging (worktree-specific)"
fi

# Exclude .gitignore from commit — sharkrite modifies it to add symlink ignore
# patterns (.rite, .claude, node_modules) but these shouldn't be committed to
# the target repo. The working tree copy stays modified (needed for ignore rules).
git reset HEAD .gitignore 2>/dev/null || true

git commit -m "$COMMIT_MSG" > /dev/null

if [ "$AUTO_MODE" = true ]; then
  echo "✅ Committed: $COMMIT_SUBJECT"
else
  print_success "Commit created"
  echo ""
fi

# Push workflow
if [ "$AUTO_MODE" = false ]; then
  read -p "🚀 Push to remote? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Changes committed locally. Push later with:"
    echo "  git push -u origin $BRANCH_NAME"
    exit 0
  fi
else
  echo "🚀 Pushing to remote..."
fi

# Push with upstream tracking (suppress git's verbose output)
if ! git push -u origin "$BRANCH_NAME" >/dev/null 2>&1; then
  # Push failed — check for remote divergence
  print_warning "Push rejected — checking for divergence"
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"

  if detect_divergence "$BRANCH_NAME"; then
    handle_push_divergence "$BRANCH_NAME" "${ISSUE_NUMBER:-}" "" "$AUTO_MODE" || {
      print_error "Could not resolve divergence during post-dev push"
      exit 1
    }
  else
    print_error "Push failed (not a divergence issue)"
    exit 1
  fi
fi
print_success "Pushed to origin/$BRANCH_NAME"
echo ""
fi  # End of "if CHANGES_COUNT > 0" block
fi  # End of "if SKIP_TO_PR" block

# PR workflow - automatically handled by create-pr.sh
# Skip when called by workflow-runner.sh (RITE_ORCHESTRATED) — Phase 2/3 handle PR/review.
# Only run when claude-workflow.sh is invoked standalone (e.g., rite 42 --quick).
if [ "${RITE_ORCHESTRATED:-false}" = "true" ]; then
  print_info "Orchestrated mode — skipping PR workflow (handled by workflow-runner Phase 2/3)"
else
  verbose_header "🔗 Pull Request & Review Workflow"

  if [ -f "$RITE_LIB_DIR/core/create-pr.sh" ]; then
    if [ "$AUTO_MODE" = true ]; then
      "$RITE_LIB_DIR/core/create-pr.sh" --auto
    else
      "$RITE_LIB_DIR/core/create-pr.sh"
    fi
  else
    print_warning "create-pr.sh not found, skipping PR workflow"
    print_info "Manually create PR with: gh pr create"
  fi
fi

# Summary
print_header "🎉 Workflow Complete"

echo "Summary:"
echo "  Branch: $BRANCH_NAME"
echo "  Commits: $(git rev-list --count origin/main..HEAD 2>/dev/null || echo "1")"
echo "  Changes: $CHANGES_COUNT files"
echo ""

# Check if PR was created
PR_JSON=$(gh pr list --head "$BRANCH_NAME" --json number,title,url --jq '.[0]' 2>/dev/null || echo "")

if [ ! -z "$PR_JSON" ] && [ "$PR_JSON" != "null" ]; then
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
  PR_URL=$(echo "$PR_JSON" | jq -r '.url')

  if is_verbose; then
    echo "Next steps:"
    echo "  1. Review PR: $PR_URL"
    echo "  2. Wait for automated review (handled by create-pr.sh)"
    echo "  3. Address feedback if any (assess-and-resolve.sh)"
    echo "  4. Merge when approved"

    if [ -n "$WORKTREE_PATH" ]; then
      echo ""
      verbose_info "Worktree will be cleaned up after merge"
      echo "  Location: $WORKTREE_PATH"
    fi
  fi
else
  if is_verbose; then
    echo "Next steps:"
    echo "  1. PR creation handled by create-pr.sh"
    echo "  2. Automated review will follow"
    echo "  3. Merge when approved"
  fi
fi

# Check if still in worktree
CURRENT_PATH=$(pwd)
if [[ "$CURRENT_PATH" == *"$(basename "$RITE_WORKTREE_DIR")"* ]] || [ -n "$WORKTREE_PATH" ]; then
  echo ""
  print_info "You are in an isolated worktree"
  echo "  Location: ${WORKTREE_PATH:-$CURRENT_PATH}"
  echo "  Changes here won't affect other terminals or main worktree"
  echo "  Worktree will be cleaned up after PR merge"
fi

# Post-workflow cleanup: Exit worktree and return to main repo
CURRENT_PATH=$(pwd)
MAIN_REPO=$(git worktree list | head -1 | awk '{print $1}')

if [ -n "$MAIN_REPO" ] && [ "$CURRENT_PATH" != "$MAIN_REPO" ]; then
  echo ""
  print_info "Workflow complete - returning to main repository"
  cd "$MAIN_REPO" || cd "$HOME"
  print_success "Exited worktree: $CURRENT_PATH"
  print_info "To return to worktree: cd $CURRENT_PATH"
fi

echo ""
print_success "All done!"
