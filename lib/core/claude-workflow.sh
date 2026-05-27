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

# Source issue assessor (pre-launch state + mid-session close detection)
source "$RITE_LIB_DIR/utils/issue-assessor.sh"

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

  exit ${exit_code}
}

trap cleanup_on_interrupt INT TERM

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
# _derive_fast_test_paths
#
# Maps changed source files (vs origin/main) to candidate test paths for
# pytest. Used in batch mode to skip running ~1500 unrelated tests when only
# a handful of files changed. Returns space-separated paths on stdout, or
# empty if derivation can't produce a useful subset.
#
# Heuristic:
#   1. Any tests/ paths the diff itself touched (added or modified) are kept.
#   2. For each non-test src file changed, derive matching test paths:
#        src/foo/bar.py        → tests/foo/test_bar.py and tests/foo/
#        backend/src/foo/bar.py → backend/tests/foo/test_bar.py and backend/tests/foo/
#   3. Existing paths only (skip anything that isn't on disk).
#
# Conservative: returns empty if no test paths could be derived. The caller
# falls back to the full suite, so wrong derivation degrades to "slower than
# necessary" rather than "missed coverage".
_derive_fast_test_paths() {
  local _changed
  _changed=$(git diff --name-only origin/main...HEAD 2>/dev/null) || return 1
  [ -z "$_changed" ] && return 1

  local _candidates=""
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue

    # Direct test file change.
    case "$_f" in
      tests/*|*/tests/*|test/*|*/test/*)
        [ -f "$_f" ] && _candidates+=" $_f"
        continue
        ;;
    esac

    # Map src file → matching test paths.
    case "$_f" in
      *.py)
        # src/foo/bar.py → tests/foo/test_bar.py
        local _base="${_f##*/}"
        local _dir="${_f%/*}"
        local _test_base="test_${_base}"
        # Strip leading "src/" or "backend/src/" to get the relative module path.
        local _rel="$_dir"
        case "$_dir" in
          src/*) _rel="${_dir#src/}" ;;
          src) _rel="" ;;
          backend/src/*) _rel="backend/${_dir#backend/src/}" ;;
          backend/src) _rel="backend" ;;
        esac
        # Determine test root prefix (backend/tests/ or tests/).
        local _troot="tests"
        case "$_dir" in
          backend/*) _troot="backend/tests" ;;
        esac
        # Strip the leading project root from _rel for test path
        local _test_rel="${_rel#tests/}"
        _test_rel="${_test_rel#backend/}"
        local _candidate_file="${_troot}/${_test_rel}/${_test_base}"
        local _candidate_dir="${_troot}/${_test_rel}"
        _candidate_file="${_candidate_file//\/\//\/}"
        _candidate_dir="${_candidate_dir//\/\//\/}"
        [ -f "$_candidate_file" ] && _candidates+=" $_candidate_file"
        [ -d "$_candidate_dir" ] && _candidates+=" $_candidate_dir"
        ;;
      *.js|*.jsx|*.ts|*.tsx)
        # Front-end mapping handled by jest --findRelatedTests; for now,
        # only direct test-file diffs feed the candidate list.
        :
        ;;
    esac
  done <<< "$_changed"

  # Always include integration/e2e directories if they exist (cross-cutting tests
  # that the file-name heuristic doesn't catch). Configurable via env.
  local _always="${RITE_BATCH_FAST_TESTS_ALWAYS_INCLUDE:-tests/integration tests/e2e backend/tests/integration backend/tests/e2e}"
  for _p in $_always; do
    [ -d "$_p" ] && _candidates+=" $_p"
  done

  # Dedupe and trim.
  _candidates=$(echo "$_candidates" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
  _candidates="${_candidates% }"

  echo "$_candidates"
}

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

  # Defensive: re-ensure the venv symlinks exist. The session-start unconditional
  # block creates them, but a fix session may have run `git rm backend/.venv` to
  # address review feedback (the previous review kept flagging the symlink as
  # "committed to repo"). When that happens, the symlink in the working tree
  # gets deleted along with the index entry, and the test gate falls back to
  # system python — which usually has no pytest. Recreate symlinks here so the
  # gate always runs against the shared venv.
  local _gate_main_wt
  _gate_main_wt=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}' || echo "")
  if [ -n "$_gate_main_wt" ] && [ "$(pwd)" != "$_gate_main_wt" ]; then
    for _gate_rel in ".venv" "backend/.venv"; do
      local _gate_main="$_gate_main_wt/$_gate_rel"
      [ -d "$_gate_main" ] || continue
      [ -d "$(dirname "$_gate_rel")" ] || continue
      # Skip if already a working symlink to the desired target.
      if [ -L "$_gate_rel" ] && [ "$(readlink "$_gate_rel" 2>/dev/null)" = "$_gate_main" ]; then
        continue
      fi
      [ -e "$_gate_rel" ] || [ -L "$_gate_rel" ] && rm -rf "$_gate_rel" 2>/dev/null
      ln -s "$_gate_main" "$_gate_rel" 2>/dev/null || true
    done
  fi
  unset _gate_main_wt _gate_rel _gate_main

  # Detect test command: RITE_TEST_CMD override → auto-detect from project structure
  local _test_cmd="${RITE_TEST_CMD:-}"
  local _test_subdir=""

  if [ -z "$_test_cmd" ]; then
    # npm test: only if package.json has a real test script (not missing, not placeholder).
    # Detect vitest/jest and force non-watch mode. The `-- --run` (vitest) and `-- --ci`
    # (jest) flags pass through npm to the underlying runner.
    local _npm_test_dir=""
    if [ -f "package.json" ] && node -e "const p=require('./package.json'); if(p.scripts?.test && !/^echo /i.test(p.scripts.test)) process.exit(0); else process.exit(1)" 2>/dev/null; then
      _npm_test_dir="."
    elif [ -f "backend/package.json" ] && (cd backend && node -e "const p=require('./package.json'); if(p.scripts?.test && !/^echo /i.test(p.scripts.test)) process.exit(0); else process.exit(1)" 2>/dev/null); then
      _npm_test_dir="backend"
      _test_subdir="backend"
    fi
    if [ -n "$_npm_test_dir" ]; then
      # Inspect the test script to pick the right non-watch flag
      local _test_script
      _test_script=$(node -e "console.log(require('./$_npm_test_dir/package.json').scripts?.test || '')" 2>/dev/null)
      if echo "$_test_script" | grep -qE "(^|[^a-z])vitest([^a-z]|$)" && ! echo "$_test_script" | grep -qE "(--run|\brun\b)"; then
        _test_cmd="npm test -- --run"
      elif echo "$_test_script" | grep -qE "(^|[^a-z])jest([^a-z]|$)" && ! echo "$_test_script" | grep -qE "(--ci|--watchAll=false)"; then
        _test_cmd="npm test -- --ci --watchAll=false"
      else
        _test_cmd="npm test"
      fi
    fi

    # Python tests: detect via any pytest/test markers at root OR backend/.
    if [ -z "$_test_cmd" ]; then
      local _has_python_tests=false
      if [ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || [ -f "setup.cfg" ] || [ -f "setup.py" ] \
         || [ -d "tests" ] || [ -d "backend/tests" ] \
         || [ -f "backend/pytest.ini" ] || [ -f "backend/pyproject.toml" ]; then
        _has_python_tests=true
      fi

      if [ "$_has_python_tests" = true ]; then
        # Locate the venv independently of where pytest config lives. Layouts
        # vary (e.g. invoi has `pytest.ini` at root with `testpaths=backend/tests`
        # but the venv is at `backend/.venv`) and tying venv lookup to config
        # location produced false-fallbacks to system python. Walk candidates
        # in priority order; the first matching venv wins, and `_test_subdir`
        # is set to wherever that venv lives so pytest runs with the right CWD.
        # Worktrees inherit the main repo's venv via symlink at session start —
        # never auto-create here (silent half-installed venvs poison every run).
        local _venv_pairs=(
          ".:.venv" ".:venv" ".:env"
          "backend:.venv" "backend:venv" "backend:env"
        )
        for _pair in "${_venv_pairs[@]}"; do
          local _candidate_dir="${_pair%%:*}"
          local _candidate_venv="${_pair#*:}"
          if [ -f "$_candidate_dir/$_candidate_venv/bin/python" ]; then
            _test_cmd="$_candidate_venv/bin/python -m pytest"
            [ "$_candidate_dir" = "." ] || _test_subdir="$_candidate_dir"
            break
          fi
        done
        if [ -z "$_test_cmd" ] && [ -n "${RITE_PROJECT_ROOT:-}" ] && [ -f "$RITE_PROJECT_ROOT/.venv/bin/python" ]; then
          _test_cmd="$RITE_PROJECT_ROOT/.venv/bin/python -m pytest"
        fi
        if [ -z "$_test_cmd" ]; then
          if command -v python3 >/dev/null 2>&1; then
            _test_cmd="python3 -m pytest"
          else
            _test_cmd="python -m pytest"
          fi
        fi
      fi
    fi

    if [ -z "$_test_cmd" ] && [ -f "Makefile" ] && grep -q "^test:" "Makefile" 2>/dev/null; then
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

    # Verify pytest is actually importable. A broken venv (empty bin/, missing
    # pytest, partial pip install) silently fails the gate with "No module named
    # pytest" on every run. Catch it once with a clear remediation path.
    local _pytest_check_dir="${_test_subdir:-.}"
    if ! (cd "$_pytest_check_dir" && $_python_bin -c "import pytest" 2>/dev/null); then
      print_error "pytest not importable in $_pytest_check_dir/$_python_bin"
      print_info "The venv exists but is missing pytest (or other deps)."
      print_info "Fix in the main repo so all worktrees inherit it via symlink:"
      if [ -n "${RITE_PROJECT_ROOT:-}" ]; then
        print_info "  cd $RITE_PROJECT_ROOT/$_pytest_check_dir"
      else
        print_info "  cd <main-repo>/$_pytest_check_dir"
      fi
      print_info "  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
      print_info "Or skip the gate for one run: export RITE_SKIP_TESTS=true"
      exit 3
    fi

    # Parallel execution via xdist (use if already installed, never auto-install)
    if ! echo "$_test_cmd" | grep -qE "\-n "; then
      if $_python_bin -c "import xdist" 2>/dev/null; then
        _test_cmd="$_test_cmd -n auto"
      fi
    fi

    # Short tracebacks, suppress deprecation warnings, quiet output
    _test_cmd="$_test_cmd --tb=short -W ignore::DeprecationWarning -q"

    # Batch fast-test mode: when running inside a batch and the user hasn't
    # opted out, restrict pytest to test paths derived from the diff.
    # The end-of-batch verification phase runs the full suite once before
    # cutting any final fix loop, so missed coverage here is caught later.
    if [ "${BATCH_MODE:-false}" = true ] \
       && [ "${RITE_BATCH_FAST_TESTS:-true}" != "false" ] \
       && [ -z "${RITE_TEST_CMD:-}" ]; then
      local _fast_paths
      _fast_paths=$(_derive_fast_test_paths 2>/dev/null || echo "")
      if [ -n "$_fast_paths" ]; then
        print_info "Batch fast-test mode: $(echo "$_fast_paths" | wc -w | tr -d ' ') target path(s)"
        _test_cmd="$_test_cmd $_fast_paths"
      fi
    fi
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
    # CI=true disables watch mode in vitest, jest, react-scripts, etc.
    # Exported inside the subshell so child processes inherit it reliably.
    export CI=true
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

        # Extract failure details from test output. Supports pytest (=== FAILURES ===)
        # and vitest/jest (⎯ Failed Tests ⎯) section markers.
        local _fail_summary
        _fail_summary=$(sed -n '/=* FAILURES =*/,/=* short test summary/p' "$_test_output_file" | tail -80)
        if [ -z "$_fail_summary" ]; then
          # vitest/jest: grab the Failed Tests section through the end-of-section marker
          _fail_summary=$(sed -n '/Failed Tests/,/⎯⎯⎯⎯.*\[/p' "$_test_output_file" | tail -80)
        fi
        if [ -z "$_fail_summary" ]; then
          _fail_summary=$(grep -E "FAIL|ERROR|AssertionError|assert|Error:" "$_test_output_file" | tail -30 || true)
        fi
        # Also grab the summary line (e.g., "2 failed, 864 passed" or "Tests  1 failed | 38 passed")
        local _fail_counts
        _fail_counts=$(grep -E "failed.*passed|error.*passed" "$_test_output_file" | tail -1 || true)

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
        local _fix_stderr
        _fix_stderr=$(mktemp)
        provider_run_agentic_session "$_fix_prompt" "${RITE_FIX_TIMEOUT:-1800}" true "$_fix_stderr" || _fix_exit=$?
        _timer_end "test_fix_session"
        if [ -s "$_fix_stderr" ]; then
          print_warning "Test fix session stderr:"
          cat "$_fix_stderr" >&2
        fi
        rm -f "$_fix_stderr"

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
# UNCONDITIONAL VENV BOOTSTRAP + WORKTREE REPAIR
# Runs on every code path (dev, fix-review, anything else). Both modes
# end up calling run_test_gate(), and both need the venv to be healthy
# (and worktree symlinks to point at the right place) before that.
# Previously this only ran in the dev path, so fix-review mode hit a
# broken venv with no chance to repair.
# ===================================================================
_actual_main_wt=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}' || echo "")
if [ -n "$_actual_main_wt" ]; then
  _ensure_main_venv() {
    local _d="$1"
    [ -d "$_d" ] || return 0
    [ -f "$_d/requirements.txt" ] || return 0
    [ "${RITE_AUTO_BOOTSTRAP_VENV:-true}" = "false" ] && return 0
    if [ -f "$_d/.venv/bin/python" ] && \
       (cd "$_d" && .venv/bin/python -c "import pytest" 2>/dev/null); then
      return 0
    fi
    if [ -d "$_d/.venv" ]; then
      print_warning "Existing venv at $_d/.venv is missing pytest — recreating"
      rm -rf "$_d/.venv"
    fi
    print_status "Bootstrapping Python venv at $_d/.venv (one-time setup)..."
    if ! (cd "$_d" && python3 -m venv .venv); then
      print_error "Failed to create venv at $_d/.venv"
      return 1
    fi
    print_status "Installing requirements (this may take a minute)..."

    # Locate brew up-front. Apple Silicon's /opt/homebrew/bin isn't always on
    # the PATH inherited via launchd, sudo, IDE wrappers, etc., so a bare
    # `command -v brew` lookup can return false even when brew is installed —
    # silently disabling the system-dep auto-installer below.
    local _brew=""
    if command -v brew >/dev/null 2>&1; then
      _brew="brew"
    elif [ -x /opt/homebrew/bin/brew ]; then
      _brew=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then
      _brew=/usr/local/bin/brew
    fi

    # Run pip and reliably capture its exit code. The previous form
    # `if ! pipeline; then : ; fi; _exit=${PIPESTATUS[0]}` had a fatal bug:
    # the `:` no-op runs on failure (because `!` inverts, putting us in the
    # `then` branch) and itself updates PIPESTATUS to (0), wiping pip's exit
    # code. Use the `|| _var=${PIPESTATUS[0]}` idiom — `||` only fires the
    # parameter assignment, no extra command runs that could clobber state.
    local _pip_log
    _pip_log=$(mktemp)
    local _pip_exit=0
    (cd "$_d" && .venv/bin/pip install -q -r requirements.txt) 2>&1 | tee "$_pip_log" \
      || _pip_exit=${PIPESTATUS[0]}

    if [ "$_pip_exit" -ne 0 ]; then
      # Detect missing system libs from pip output and brew install them, then
      # retry pip once. Common case: pycairo, lxml, psycopg2, Pillow on a fresh
      # macOS box without their underlying brew libs.
      local _brew_pkgs=""
      if [ -n "$_brew" ]; then
        # pkg-config / cmake / meson tooling
        grep -qE "Did not find pkg-config|[Pp]kg-config.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs pkg-config"
        grep -qE "Did not find CMake|CMake.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs cmake"
        # Library deps surfaced by meson's "Run-time dependency X found: NO"
        # and similar messages. Map a small known set of common ones.
        grep -qE "dependency cairo found: NO|cairo.*not found|cairo/cairo\.h.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs cairo"
        grep -qE "dependency libxml-?2.* found: NO|libxml/parser\.h.*not found|xmlversion\.h.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs libxml2"
        grep -qE "dependency libxslt.* found: NO|libxslt/.*\.h.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs libxslt"
        grep -qE "pg_config.*not (found|on the path)|pg_config executable not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs postgresql"
        grep -qE "openssl/.*\.h.*not found|libssl.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs openssl"
        grep -qE "ffi\.h.*not found|libffi.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs libffi"
        grep -qE "jpeglib\.h.*not found|libjpeg.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs jpeg"
        grep -qE "freetype/.*\.h.*not found|freetype.*not found" "$_pip_log" && _brew_pkgs="$_brew_pkgs freetype"
        _brew_pkgs="${_brew_pkgs# }"
      fi

      if [ -n "$_brew_pkgs" ]; then
        print_warning "Pip install failed due to missing system libraries: $_brew_pkgs"
        print_status "Installing via brew (one-time per machine)..."
        local _brew_exit=0
        # shellcheck disable=SC2086
        "$_brew" install $_brew_pkgs || _brew_exit=$?
        if [ "$_brew_exit" -eq 0 ]; then
          print_status "Retrying pip install with system deps installed..."
          : > "$_pip_log"
          _pip_exit=0
          (cd "$_d" && .venv/bin/pip install -q -r requirements.txt) 2>&1 | tee "$_pip_log" \
            || _pip_exit=${PIPESTATUS[0]}
        else
          print_error "brew install failed (exit $_brew_exit) for: $_brew_pkgs"
        fi
      elif [ -z "$_brew" ]; then
        print_warning "pip install failed and brew not found at /opt/homebrew/bin or /usr/local/bin"
        print_info "Install Homebrew or install system deps manually, then retry"
      fi

      if [ "$_pip_exit" -ne 0 ]; then
        print_error "Failed to install requirements at $_d/.venv"
        print_info "Inspect: cd $_d && .venv/bin/pip install -r requirements.txt"
        rm -f "$_pip_log"
        return 1
      fi
    fi
    rm -f "$_pip_log"
    if [ -f "$_d/requirements-dev.txt" ]; then
      print_status "Installing dev requirements..."
      (cd "$_d" && .venv/bin/pip install -q -r requirements-dev.txt) || \
        print_warning "Dev requirements install failed (continuing)"
    fi
    if (cd "$_d" && .venv/bin/python -c "import pytest" 2>/dev/null); then
      print_success "Venv ready at $_d/.venv"
    else
      print_warning "Bootstrap completed but pytest still not importable in $_d/.venv"
      print_info "Add pytest to requirements.txt or requirements-dev.txt"
    fi
  }
  _ensure_main_venv "$_actual_main_wt" || true
  _ensure_main_venv "$_actual_main_wt/backend" || true

  # If we're in a worktree (cwd != main), ensure local .venv is a working
  # symlink to main's. Replaces broken symlinks, broken directories, or
  # missing entries. Also untracks the symlink from git if a previous run
  # accidentally committed it — otherwise the next review flags it as "symlink
  # committed to repo" and the fix session does `git rm backend/.venv`, which
  # destroys the very thing the test gate needs.
  _link_venv_into_worktree() {
    local _rel="$1"
    local _main_path="$_actual_main_wt/$_rel"
    local _local_path="./$_rel"
    [ -d "$_main_path" ] || return 0
    # Untrack a previously-committed (or staged-deleted) .venv symlink so
    # reviewers don't keep flagging it. Both `--cached` (file present) and
    # `git reset HEAD --` (file absent, deletion staged) handle the cases.
    if git ls-files --error-unmatch "$_local_path" >/dev/null 2>&1; then
      git rm --cached -q "$_local_path" 2>/dev/null || true
    elif git diff --cached --name-only 2>/dev/null | grep -qxF "${_local_path#./}"; then
      git reset -q HEAD -- "$_local_path" 2>/dev/null || true
    fi
    # Already a working symlink to the desired target — leave it alone.
    if [ -L "$_local_path" ] && [ "$(readlink "$_local_path" 2>/dev/null)" = "$_main_path" ]; then
      return 0
    fi
    if [ -e "$_local_path" ] || [ -L "$_local_path" ]; then
      rm -rf "$_local_path" 2>/dev/null || return 0
    fi
    local _parent
    _parent=$(dirname "$_local_path")
    [ -d "$_parent" ] || return 0
    ln -s "$_main_path" "$_local_path" 2>/dev/null || true
  }
  if [ "$(pwd)" != "$_actual_main_wt" ]; then
    _link_venv_into_worktree ".venv"
    _link_venv_into_worktree "backend/.venv"
  fi
fi
unset _actual_main_wt

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

  # Worktree directory is per-issue only. Batch context (sibling issues) is
  # recorded in a sidecar file so it's available to tooling but not visible to
  # the worker's filesystem chrome — the directory name should not advertise
  # other issues, since that has been observed to encourage the LLM to bundle
  # work across issues into a single worktree.

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
            # A worktree with 2 commits ahead + 0 uncommitted + open PR is NOT eligible for cleanup;
            # deleting it strands the user's review work mid-flow.
            OPEN_PR_COUNT=$(gh pr list --head "$WT_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo "0")
            if [ "$OPEN_PR_COUNT" -gt 0 ]; then
              PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
              continue
            fi

            # Hard guard 3: skip if local commits are ahead of remote (unpushed work).
            # The remote ref may not exist yet if push hasn't happened; in that case
            # any local commit beyond main is unpushed and protected.
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
            print_status "Removing stale worktree: $OLDEST_BRANCH (${DAYS_OLD} days old, no PR, no uncommitted or unpushed work)"
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

    # Record batch context (if any) in a sidecar file inside the worktree's git
    # metadata, NOT in the worktree directory name. The directory name should
    # only identify this issue — surfacing sibling issue numbers in the path
    # has been observed to encourage the LLM to bundle work across issues.
    if [ "${BATCH_MODE:-false}" = true ] && [ -n "${BATCH_ISSUE_LIST:-}" ]; then
      _batch_sidecar_dir="${RITE_PROJECT_ROOT:-$MAIN_WORKTREE}/$RITE_DATA_DIR/batch-context"
      mkdir -p "$_batch_sidecar_dir" 2>/dev/null || true
      printf '%s\n' "$BATCH_ISSUE_LIST" > "$_batch_sidecar_dir/${ISSUE_NUMBER:-${SAFE_BRANCH_NAME}}.txt" 2>/dev/null || true
    fi

    # Add symlink patterns to .gitignore BEFORE creating symlinks
    # This prevents them from ever appearing as untracked files in git status
    ensure_symlinks_gitignored() {
      local gitignore="$WORKTREE_PATH/.gitignore"
      # No trailing slashes — "foo/" only matches directories, but symlinks are
      # files (mode 120000) so "foo/" won't match them. "foo" matches both.
      local patterns=(".rite" ".claude" "node_modules" "backend/node_modules" ".venv" "backend/.venv")
      local updated=0

      for pattern in "${patterns[@]}"; do
        # Already has the correct (no-slash) entry — nothing to do
        if [ -f "$gitignore" ] && grep -qxF "$pattern" "$gitignore" 2>/dev/null; then
          continue
        fi
        # Has the old trailing-slash form that doesn't match symlinks — upgrade it
        if [ -f "$gitignore" ] && grep -qxF "${pattern}/" "$gitignore" 2>/dev/null; then
          sed -i '' "s|^${pattern}/$|${pattern}|" "$gitignore"
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

    # Symlink shared directories — but only when running in an actual worktree.
    # If WORKTREE_PATH == MAIN_WORKTREE (e.g., rite ran from the main repo on a
    # feature branch instead of from a worktree), symlinking would delete the real
    # directory and create a circular self-referential symlink.
    if [ "$WORKTREE_PATH" != "$MAIN_WORKTREE" ]; then
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

      # Symlink Python venvs from main into the new worktree. Bootstrap (if
      # main has no venv) already ran near the top of this file, so by the
      # time we get here main is either healthy or we already failed loudly.
      if [ -d "$MAIN_WORKTREE/.venv" ]; then
        rm -rf "$WORKTREE_PATH/.venv" 2>/dev/null || true
        ln -s "$MAIN_WORKTREE/.venv" "$WORKTREE_PATH/.venv" 2>/dev/null || true
      fi
      if [ -d "$MAIN_WORKTREE/backend/.venv" ] && [ -d "$WORKTREE_PATH/backend" ]; then
        rm -rf "$WORKTREE_PATH/backend/.venv" 2>/dev/null || true
        ln -s "$MAIN_WORKTREE/backend/.venv" "$WORKTREE_PATH/backend/.venv" 2>/dev/null || true
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
for _pattern in ".rite" ".claude" "node_modules" "backend/node_modules" ".venv" "backend/.venv"; do
  # Already has the correct (no-slash) entry — nothing to do
  if [ -f .gitignore ] && grep -qxF "$_pattern" .gitignore 2>/dev/null; then
    continue
  fi
  # Has the old trailing-slash form — upgrade it
  if [ -f .gitignore ] && grep -qxF "${_pattern}/" .gitignore 2>/dev/null; then
    sed -i '' "s|^${_pattern}/$|${_pattern}|" .gitignore
    continue
  fi
  # Pattern missing entirely — add it
  echo "$_pattern" >> .gitignore
done

# (Venv bootstrap + worktree symlink repair runs unconditionally near the
# top of this file, before the FIX_REVIEW_MODE early exit, so all code
# paths benefit. See the "UNCONDITIONAL VENV BOOTSTRAP" block above.)

# Defensive merge: ensure branch is up-to-date with origin/main before starting work
# Prevents merge conflicts at PR time, especially in batch mode where earlier issues
# merge to main while later issues are still working on stale branches.
# New branches (just created from origin/main) will show 0 behind — this is a no-op for them.
if [[ "$BRANCH_NAME" != "main" && "$BRANCH_NAME" != "develop" ]]; then
  git fetch origin main 2>/dev/null || true
  BEHIND_COUNT=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
  if [ "$BEHIND_COUNT" -gt 0 ]; then
    print_status "Branch is $BEHIND_COUNT commit(s) behind main — merging origin/main..."
    _defensive_merge_ok=false
    if git merge origin/main --no-edit 2>/dev/null; then
      _defensive_merge_ok=true
    else
      # Merge conflict — try Claude-assisted resolution before giving up.
      # Resolver expects to be in conflict state (we are) and aborts on its
      # own failure path, leaving the working tree clean.
      if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        print_warning "Merge with main had conflicts ($BEHIND_COUNT commits behind) — attempting Claude-assisted resolution..."
        source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
        _resolve_args=(--merge-target origin/main --branch-name "$BRANCH_NAME")
        [ -n "${ISSUE_NUMBER:-}" ] && _resolve_args+=(--issue-number "$ISSUE_NUMBER")
        if attempt_claude_merge_resolution "${_resolve_args[@]}"; then
          if git commit --no-edit 2>/dev/null; then
            _defensive_merge_ok=true
          else
            git reset --hard HEAD 2>/dev/null || true
          fi
        fi
      else
        git merge --abort 2>/dev/null || true
      fi

      if [ "$_defensive_merge_ok" != true ]; then
        print_error "Merge conflict with main ($BEHIND_COUNT commits behind)"
        print_info "Resolve manually: git merge origin/main"
        exit 1
      fi
    fi

    if [ "$_defensive_merge_ok" = true ]; then
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
    sed -i '' "/## Current Work/a\\
\\
**Issue:** #${ISSUE_NUMBER:-unknown}\\
**Description:** ${ISSUE_DESC}\\
**Branch:** ${BRANCH_NAME:-$CURRENT_BRANCH}\\
**Started:** $(date '+%Y-%m-%d %H:%M:%S')\\
" "$TEMP_SCRATCH"
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

Out-of-scope issues (test failures, security concerns, code smells, deprecations, missing docs): do NOT fix or block on them. Log to scratchpad under \"## Encountered Issues (Needs Triage)\" for triage into tech-debt tickets at merge time.

Format: \`- **YYYY-MM-DD** | \\\`file:line\\\` | category | Description | Affects: ... | Fix: ... | Done: ...\`
Categories: test-failure, security, code-smell, missing-docs, deprecation, performance
"

# Pre-classified dependency context. The worker would otherwise read the
# issue body and interpret \"After: #M\" / \"Depends on: #M\" lines as a todo.
# Surfacing them here, framed as already-merged context, makes the scope wall
# below operational rather than aspirational.
DEPENDENCY_CONTEXT_PROMPT=""
# ISSUE_BODY may not be in scope on every entry path (orchestrated runs export
# only NORMALIZED_SUBJECT/WORK_DESCRIPTION). Fetch it lazily if missing.
if [ -z "${ISSUE_BODY:-}" ] && [ -n "${ISSUE_NUMBER:-}" ]; then
  ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body --jq '.body // ""' 2>/dev/null || echo "")
fi
if [ -n "${ISSUE_BODY:-}" ]; then
  _dep_refs=$(echo "$ISSUE_BODY" | grep -oiE '(After:? #|Depends on:? #|Blocked by:? #)[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)
  if [ -n "${_dep_refs:-}" ]; then
    DEPENDENCY_CONTEXT_PROMPT="

## Dependencies (assume merged in main)

This issue references: $(echo "$_dep_refs" | sed 's/ /, #/g; s/^/#/; s/, #$//')

Treat each referenced issue as **already merged in \`main\`**. Their code is
your starting point, not your todo list. If you read \`main\` and a
dependency's code is missing, do NOT implement it — see the Scope Wall below.
"
  fi
fi

# Scope wall — explicit per-issue boundary. Without this, when the worker
# encounters an unsatisfied dependency (\"After: #M\"), it tends to implement
# #M's work in this issue's worktree rather than logging the gap. Empty
# parent PRs become populated by sibling workers, work files end up in the
# wrong worktree, and parent issues silently \"complete\" with no commits.
SCOPE_WALL_PROMPT="

## Scope Wall (CRITICAL)

This session implements **issue #${ISSUE_NUMBER:-N/A} ONLY**. Every commit must
serve this issue's acceptance criteria. Do not implement work that belongs to
another issue, even one this issue depends on.

**Dependency lines** (\`After: #M\`, \`Depends on: #M\`, \`Blocked by: #M\`) are
context, not a todo list. Treat referenced issues as already-merged in \`main\`.
If you read \`main\` and discover a dependency's code is missing:

1. Do NOT implement #M here. Even if it looks like a small step, it is not.
2. Log the gap to the scratchpad's \"## Encountered Issues\" section as
   \`missing-dependency | #M | <what's missing>\`.
3. Implement what you can of issue #${ISSUE_NUMBER:-N/A} that doesn't depend on
   the missing piece. If nothing is implementable without #M, stop and report.

**Files outside scope:** Never edit a file by its absolute path into a
sibling worktree. Only modify files under your current working directory
(\`pwd\`). The rite workflow runs each issue in its own worktree — writing to
another worktree's files is a bug, not a shortcut.

**Self-check before exiting:** Every file you modified must trace back to an
acceptance criterion of issue #${ISSUE_NUMBER:-N/A}. If you can't justify a
modification, revert it.
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
${SECURITY_PROMPT}${DEPENDENCY_CONTEXT_PROMPT}${RESUME_CONTEXT_PROMPT:-}${SCOPE_WALL_PROMPT}${ENCOUNTERED_ISSUES_PROMPT}
## Implementation Rigor

For issues with labels \`tech-debt\` or \`from-review\`: the issue describes a **gap in existing code**. The code the issue was filed against already exists on \`main\`. Your job is to implement what's MISSING, not confirm what's PRESENT. Identify the **delta** between current state and done state before touching any code.

**Acceptance Criteria Mapping** (mandatory before concluding \"already complete\"):
For EACH acceptance criterion, produce: \`[criterion text] → [file:line] — [why this satisfies it]\`. If you cannot map every criterion, work is NOT complete.

**Anti-patterns to avoid:**
- **Surface-match trap:** Finding code that LOOKS like what the issue describes and stopping. Read the code — does it actually satisfy the acceptance criteria?
- **Parent-PR confusion:** If the issue says \"from PR #N\", that PR is already merged. You are here because something about that code is insufficient.
- **Zero-change exit:** If about to exit with no file changes, STOP. Re-read the issue body and acceptance criteria. Produce the explicit mapping or keep working.

$(if [ "${RITE_NO_CHANGE_RETRY:-false}" = "true" ]; then
cat <<'RETRY_WARNING'
## ⚠️ RETRY — Previous Session Produced Zero Changes

The previous development session exited with NO file modifications. It likely concluded the work was "already complete" — **that assessment was WRONG**. The code changes described in the issue DO NOT EXIST yet. Do not repeat the same mistake.

**On this retry you MUST:**
1. \`grep\` for the specific functions, parameters, or patterns the acceptance criteria describe
2. If grep finds nothing, the work is NOT done — implement it
3. Do NOT trust your own reading of files at face value — hallucinated line references caused the previous false positive
4. Do NOT check for open PRs or conclude work is done based on PR existence — the previous PR was empty
RETRY_WARNING
fi)
## Workflow Instructions

### Phase 0: Requirements Clarification
${PHASE_0_INSTRUCTIONS}

### Phase 1: Analysis
1. **Check if work is already complete** — but be precise:
   - Verify acceptance criteria against the **specific domain/feature** the issue targets, not similar patterns elsewhere
   - If the issue references a parent PR, check what domain/files that PR touched — your verification must cover that same domain
   - Only conclude \"already complete\" if every acceptance criterion is met for the exact scope described (produce the mapping above)
   - **For tech-debt/from-review issues:** existing code in the area is EXPECTED — the issue was filed against it. Related code existing is the starting point, not the finish line.
2. If work is genuinely complete:
   - Report findings with evidence (file paths + line numbers)
   - Check if a PR exists (use: gh pr list --search \"<issue-title>\" --state all). If PR exists on a different branch, close this branch (duplicate). If no PR, skip to Phase 4 (Testing) then continue workflow.
3. If work is incomplete:
   - Read relevant files. If a listed file doesn't exist, check if a dependency (After: #N) accounts for its creation. If no dependency covers it, log to scratchpad as \`missing-dependency\`.
   - Search for related patterns, review project documentation (CLAUDE.md, docs/Technical-Specs.md)
   - **For security-sensitive code**, consult docs/security/DEVELOPMENT-GUIDE.md

### Phase 2: Planning
1. Explain your proposed implementation approach
2. List all files you'll create or modify
3. Identify potential issues or trade-offs
4. ${AUTO_MODE_INSTRUCTION}

### Phase 3: Implementation
1. Implement the solution following best practices
2. Follow existing code patterns and conventions
3. Add proper error handling and comments for complex logic
4. Do NOT update docs/, README, or CHANGELOG — handled by a separate review phase

### Phase 4: Testing & Validation
1. Before writing tests, read 1-2 existing test files in the same directory and match their setup, teardown, fixtures, and assertion patterns exactly — do not invent new test infrastructure
2. Write or update unit tests for the code you changed
3. Verify your new code imports/compiles without errors (quick syntax check)
4. Do NOT run the full test suite — the rite workflow runs it automatically after this session

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
  # Record session start for the post-session sibling-worktree write guard.
  SESSION_START_EPOCH=$(date +%s)
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
      # Diagnostic-only. Must not tear down the workflow when the stderr file
      # contains only EDIT markers (grep -v returns 1 with pipefail -> set -e).
      _filtered_stderr=$({ grep -v $'^EDIT\t' "$CLAUDE_STDERR_FILE" || true; } | tail -30 | sed 's/^/  /')
      if [ -n "$_filtered_stderr" ]; then
        echo "[DIAG] Provider stderr (last 30 lines):"
        printf '%s\n' "$_filtered_stderr"
      else
        echo "[DIAG] Provider stderr: (only EDIT markers, no errors)"
      fi
    else
      echo "[DIAG] Provider stderr: (empty)"
    fi
    echo ""
  fi

  # Stash Write/Edit/MultiEdit target paths reported by Claude during the
  # session (emitted via the stream filter in lib/providers/claude.sh).
  # Used by the "no changes detected" branch below to distinguish "Claude
  # did nothing" from "Claude reported edits but git can't see them" — the
  # latter is a worktree mismatch / sandbox / sibling-write bug, not a
  # benign empty session.
  RITE_CLAUDE_EDITED_PATHS=""
  if [ -f "${CLAUDE_STDERR_FILE:-}" ]; then
    RITE_CLAUDE_EDITED_PATHS=$(grep $'^EDIT\t' "$CLAUDE_STDERR_FILE" 2>/dev/null | cut -f2 | sort -u || true)
  fi
  rm -f "${CLAUDE_STDERR_FILE:-}" 2>/dev/null || true

  # Mid-session close detection.
  # If the issue closed during the dev session, the world has changed under
  # the worker's feet. Three cases:
  #   - Closed by a merged PR ≠ ours, criteria satisfied on main → cleanup
  #     our in-flight artifacts and exit success.
  #   - Closed manually with no closing PR → assume user resolved another way;
  #     cleanup and exit success.
  #   - Closed but criteria don't appear satisfied → abort with diagnostic.
  # See lib/utils/issue-assessor.sh for the full contract.
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    set +e
    handle_mid_session_close "$ISSUE_NUMBER" "${PR_NUMBER:-}" "${WORKTREE_PATH:-}"
    _close_check=$?
    set -e
    case "$_close_check" in
      2)
        print_success "Issue #$ISSUE_NUMBER closed during session — in-flight work pitched (empty/redundant/conflicting)"
        exit 0
        ;;
      4)
        print_success "Issue #$ISSUE_NUMBER closed during session — in-flight work adopted as additive; PR retitled with [Adopted] for human review"
        exit 0
        ;;
      1)
        print_error "Issue #$ISSUE_NUMBER closed during session but state is ambiguous"
        print_info "Leaving in-flight work in ${WORKTREE_PATH:-?} for human review"
        exit 1
        ;;
    esac
  fi

  # Sibling-worktree write guard.
  # If the worker bundled this issue's work into a sibling worktree (an
  # observed failure mode — see behavioral-design.md "Scope Wall"), this
  # worktree finishes with no source changes while another worktree gains
  # uncommitted files dated within our session window. Detect that and stop.
  if [ -n "${RITE_WORKTREE_DIR:-}" ] && [ -d "${RITE_WORKTREE_DIR:-}" ] && [ -n "${WORKTREE_PATH:-}" ]; then
    _self_changes=$(git status --porcelain 2>/dev/null | { grep -v "^.. \.gitignore$" || true; } | wc -l | tr -d ' ')
    if [ "${_self_changes:-0}" -eq 0 ]; then
      _session_start_epoch="${SESSION_START_EPOCH:-0}"
      [ "$_session_start_epoch" = "0" ] && _session_start_epoch=$(($(date +%s) - CLAUDE_TIMEOUT))
      _sibling_dirty=""
      while IFS= read -r _wt; do
        [ -z "$_wt" ] && continue
        [ "$_wt" = "$WORKTREE_PATH" ] && continue
        [ ! -d "$_wt" ] && continue
        # Only flag if the sibling has uncommitted changes AND at least one
        # changed file was modified after this session started.
        _sibling_status=$(git -C "$_wt" status --porcelain 2>/dev/null | grep -v "^.. \.gitignore$" || true)
        [ -z "$_sibling_status" ] && continue
        _recent_in_sibling=$(echo "$_sibling_status" | awk '{print $2}' | while IFS= read -r _f; do
          [ -z "$_f" ] && continue
          _mt=$(stat -f "%m" "$_wt/$_f" 2>/dev/null || stat -c "%Y" "$_wt/$_f" 2>/dev/null || echo 0)
          [ "$_mt" -gt "$_session_start_epoch" ] && echo "$_f"
        done)
        if [ -n "$_recent_in_sibling" ]; then
          _sibling_dirty="${_sibling_dirty}${_wt}\n"
        fi
      done < <(find "$RITE_WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

      if [ -n "$_sibling_dirty" ]; then
        print_error "Cross-worktree write detected — work for issue #${ISSUE_NUMBER:-?} appears to have landed in a sibling worktree."
        echo ""
        echo "This worktree has no source changes, but another worktree gained"
        echo "modified files during this session:"
        echo ""
        printf '%b' "$_sibling_dirty" | sed 's|^|  - |'
        echo ""
        echo "The dev session likely violated the scope wall and bundled this"
        echo "issue's implementation into another issue's worktree."
        echo ""
        echo "Recovery: inspect the sibling worktree, move the relevant files"
        echo "back to this branch, then re-run rite for issue #${ISSUE_NUMBER:-?}."
        exit 1
      fi
    fi
  fi
fi

# Post-Claude workflow
if [ "${SKIP_TO_PR:-false}" = true ]; then
  # PR already exists, skip commit/push and go straight to PR workflow
  echo ""
else
  # Re-ensure symlink patterns in .gitignore after Claude's session.
  # Claude may have modified .gitignore during development, dropping patterns.
  for _pattern in ".rite" ".claude" "node_modules" "backend/node_modules" ".venv" "backend/.venv"; do
    if [ -f .gitignore ] && grep -qxF "$_pattern" .gitignore 2>/dev/null; then
      continue
    fi
    if [ -f .gitignore ] && grep -qxF "${_pattern}/" .gitignore 2>/dev/null; then
      sed -i '' "s|^${_pattern}/$|${_pattern}|" .gitignore
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

    # If Claude actually issued Write/Edit calls, this isn't "Claude decided
    # nothing was needed" — the edits landed somewhere git can't see (wrong
    # CWD, absolute path outside the worktree, sandbox redirect). Surface
    # the raw target paths so the next run isn't blind.
    if [ -n "${RITE_CLAUDE_EDITED_PATHS:-}" ]; then
      _edit_count=$(printf '%s\n' "$RITE_CLAUDE_EDITED_PATHS" | grep -c . || true)
      _worktree_root=$(pwd)
      print_warning "Claude reported $_edit_count file edit(s) during the session, but the worktree shows none."
      echo ""
      echo "Reported edit targets:"
      _outside=0
      while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        case "$_p" in
          "$_worktree_root"/*|./*|[!/]*)
            echo "  • $_p (in-worktree but missing — may have been reverted/rolled back)"
            ;;
          *)
            echo "  • $_p (OUTSIDE this worktree)"
            _outside=$((_outside + 1))
            ;;
        esac
      done <<< "$RITE_CLAUDE_EDITED_PATHS"
      echo ""
      if [ $_outside -gt 0 ]; then
        print_info "$_outside edit(s) targeted absolute paths outside this worktree."
        print_info "Common cause: Claude resolved paths against a sourced .env from the main repo instead of the worktree CWD."
      else
        print_info "All edits targeted in-worktree paths but git sees no changes — likely rolled back during the session."
      fi
      echo ""
    else
      print_info "This can happen if:"
      echo "  • The task was already complete"
      echo "  • Claude determined no changes were needed"
      echo "  • The session timed out before making changes"
      echo ""
    fi

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
