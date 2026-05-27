#!/usr/bin/env bash
# batch-process-issues.sh
# Batch process multiple GitHub issues in unsupervised mode
# Usage:
#   rite 19 21 31 32              # Process specific issues
#   rite --label bug              # Process all issues with label
#   rite --milestone v1.0         # Process all issues in milestone
#
# Features:
#   - Unsupervised batch processing (--auto mode for all issues)
#   - Session limit enforcement (8 issues OR 4 hours)
#   - Smart follow-up pairing (fix → merge parent PR)
#   - Progress tracking and notifications
#   - Automatic worktree management
#   - Comprehensive summary report

set -euo pipefail

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Source libraries
source "$RITE_LIB_DIR/utils/session-tracker.sh"
source "$RITE_LIB_DIR/utils/notifications.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"

source "$RITE_LIB_DIR/utils/colors.sh"

# ===================================================================
# End-of-batch verification phase
#
# Runs ONCE after all per-issue workflows finish, regardless of how many
# passed/failed/blocked. Validates that the cumulative state of main is
# healthy after this batch's squash merges. If the full suite fails, opens
# a fix loop in a dedicated worktree, runs Claude with the failures + the
# batch's merge SHAs as context, and pushes a hotfix PR.
#
# Reliability contract:
#   - Always runs (no early exit if some issues failed earlier).
#   - Treats its own failures as recoverable: at most RITE_BATCH_FIX_ATTEMPTS
#     iterations of fix → test → repeat (default 3).
#   - On final failure, leaves the fix branch + open PR + fix-main issue for
#     manual handoff. Never silently swallows a broken main.
# ===================================================================

# Detects the project's full test command. Returns command on stdout; empty
# string if nothing detectable. Honors RITE_TEST_CMD as the override.
_eob_detect_test_cmd() {
  if [ -n "${RITE_TEST_CMD:-}" ]; then
    echo "$RITE_TEST_CMD"
    return 0
  fi
  local _root="${RITE_PROJECT_ROOT:-.}"
  if [ -f "$_root/package.json" ]; then
    echo "npm test"
    return 0
  fi
  if [ -f "$_root/backend/package.json" ]; then
    echo "(cd backend && npm test)"
    return 0
  fi
  for _venv in "$_root/.venv" "$_root/venv" "$_root/backend/.venv"; do
    if [ -f "$_venv/bin/python" ] && "$_venv/bin/python" -c "import pytest" 2>/dev/null; then
      echo "$_venv/bin/python -m pytest"
      return 0
    fi
  done
  if [ -f "$_root/Makefile" ] && grep -q "^test:" "$_root/Makefile" 2>/dev/null; then
    echo "make test"
    return 0
  fi
  echo ""
}

# Runs the test command in $RITE_PROJECT_ROOT, capturing output to $1.
# Returns the test exit code.
_eob_run_full_suite() {
  local _output_file="$1"
  local _cmd
  _cmd=$(_eob_detect_test_cmd)
  if [ -z "$_cmd" ]; then
    echo "[end-of-batch] No test command detected — skipping verification" > "$_output_file"
    return 0
  fi

  # Normalize pytest flags for output cleanliness.
  if echo "$_cmd" | grep -q "pytest"; then
    if ! echo "$_cmd" | grep -qE "\-n "; then
      local _py
      _py=$(echo "$_cmd" | sed 's/ -m pytest.*//')
      if [ -n "$_py" ] && [ -x "$_py" ] && "$_py" -c "import xdist" 2>/dev/null; then
        _cmd="$_cmd -n auto"
      fi
    fi
    _cmd="$_cmd --tb=short -W ignore::DeprecationWarning -q"
  fi

  local _exit=0
  local _root="${RITE_PROJECT_ROOT:-.}"
  local _env_file=""
  [ -f "$_root/.env.test" ] && _env_file="$_root/.env.test"
  [ -z "$_env_file" ] && [ -f "$_root/.env" ] && _env_file="$_root/.env"

  (
    cd "$_root"
    if [ -n "$_env_file" ]; then
      set -a
      # shellcheck disable=SC1090
      source "$_env_file" 2>/dev/null || true
      set +a
    fi
    eval "$_cmd"
  ) 2>&1 | tee "$_output_file" || _exit=${PIPESTATUS[0]:-$?}
  return "$_exit"
}

# Runs the end-of-batch verification phase. Sets EOB_RESULT and EOB_FIX_PR
# globals for the summary section.
_run_end_of_batch_verification() {
  EOB_RESULT="skipped"
  EOB_FIX_PR=""

  # Opt-out: respect RITE_BATCH_FAST_TESTS=false (caller didn't ask for fast
  # mode, so per-issue gates already ran the full suite — no need again).
  if [ "${RITE_BATCH_FAST_TESTS:-true}" = "false" ]; then
    EOB_RESULT="skipped-not-fast-mode"
    return 0
  fi
  # Honor RITE_SKIP_TESTS as a global escape hatch.
  if [ "${RITE_SKIP_TESTS:-false}" = "true" ]; then
    EOB_RESULT="skipped-skip-tests"
    return 0
  fi

  print_header "🧪 End-of-Batch Full Test Suite"

  local _root="${RITE_PROJECT_ROOT:-.}"

  # Make sure we're testing the latest main (other workflows may have just merged).
  (cd "$_root" && git checkout main 2>/dev/null && git pull origin main 2>/dev/null) || true

  local _output
  _output=$(mktemp)
  local _exit=0
  _eob_run_full_suite "$_output" || _exit=$?

  if [ "$_exit" -eq 0 ]; then
    print_success "End-of-batch verification passed"
    EOB_RESULT="passed"
    rm -f "$_output"
    return 0
  fi

  print_warning "End-of-batch verification FAILED (exit $_exit) — launching fix loop"
  echo ""

  # Capture batch context for the fix prompt.
  local _batch_merges=""
  local _i_num
  for _i_num in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$_i_num]:-}" = "completed" ]; then
      local _pr_num="${ISSUE_PR[$_i_num]:-}"
      [ -n "$_pr_num" ] && _batch_merges+="  - #$_i_num via PR #$_pr_num"$'\n'
    fi
  done

  # Run fix loop.
  local _max_attempts="${RITE_BATCH_FIX_ATTEMPTS:-3}"
  local _attempt=0
  local _fix_branch="fix-batch-$(date -u +%Y%m%d-%H%M%S)"
  local _fix_worktree="${RITE_WORKTREE_DIR:-${_root}/../rite-wt}/eob-fix-${_fix_branch}"

  if [ ! -d "$RITE_WORKTREE_DIR" ] && [ -n "${RITE_WORKTREE_DIR:-}" ]; then
    mkdir -p "$RITE_WORKTREE_DIR" 2>/dev/null || true
  fi

  if ! git -C "$_root" worktree add -b "$_fix_branch" "$_fix_worktree" main 2>/dev/null; then
    print_error "Could not create fix worktree at $_fix_worktree"
    EOB_RESULT="failed-no-worktree"
    rm -f "$_output"
    return 1
  fi

  # Symlink .venv etc. like normal worktrees do.
  for _link in ".venv" "backend/.venv" ".env" "backend/.env"; do
    [ -e "$_root/$_link" ] || continue
    [ -e "$_fix_worktree/$_link" ] && continue
    [ -d "$(dirname "$_fix_worktree/$_link")" ] || continue
    ln -s "$_root/$_link" "$_fix_worktree/$_link" 2>/dev/null || true
  done

  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  load_provider "${RITE_DEV_PROVIDER:-claude}" 2>/dev/null || true

  local _eob_passed=false
  while [ "$_attempt" -lt "$_max_attempts" ]; do
    _attempt=$((_attempt + 1))
    print_status "Fix attempt $_attempt of $_max_attempts..."

    local _failure_excerpt
    _failure_excerpt=$(tail -200 "$_output")

    local _prompt
    _prompt=$(cat <<EOF
You are running inside a Sharkrite (\`rite\`) end-of-batch verification fix session.

A batch of GitHub issues just finished merging into main. The full test suite passed for each individual PR (in fast-test mode), but running the full suite on the cumulative state of main now fails.

Your job: identify the regression and fix it in this branch. DO NOT revert PRs; fix the underlying problem.

## Batch merges (this batch's contribution to main)
${_batch_merges:-(none completed)}

## Failing test output (tail)
\`\`\`
${_failure_excerpt}
\`\`\`

## Working directory
$(pwd)

## Rules
- Do NOT run \`git commit\`, \`git push\`, or any \`gh\` commands. Sharkrite handles those.
- Do NOT revert any of the batch's merge commits — find and fix the root cause.
- Read the failing test files, the source they exercise, and the recent merge diffs as needed.
- When done, exit. Sharkrite will run the suite again and either accept your fix or invoke you for another iteration.

Begin.
EOF
)

    (
      cd "$_fix_worktree"
      local _stderr_file
      _stderr_file=$(mktemp)
      provider_run_agentic_session "$_prompt" "${RITE_FIX_TIMEOUT:-1800}" true "$_stderr_file" || true
      rm -f "$_stderr_file"
    )

    # Re-run full suite from the fix worktree.
    local _retest_exit=0
    : > "$_output"
    (
      cd "$_fix_worktree"
      local _cmd
      _cmd=$(_eob_detect_test_cmd)
      [ -z "$_cmd" ] && exit 0
      if echo "$_cmd" | grep -q "pytest"; then
        _cmd="$_cmd --tb=short -W ignore::DeprecationWarning -q"
      fi
      eval "$_cmd"
    ) 2>&1 | tee "$_output" || _retest_exit=${PIPESTATUS[0]:-$?}

    if [ "$_retest_exit" -eq 0 ]; then
      _eob_passed=true
      break
    fi
    print_warning "Fix attempt $_attempt did not fully resolve test failures"
  done

  if [ "$_eob_passed" = true ]; then
    print_success "End-of-batch fix loop resolved test failures"
    # Commit and push, then open hotfix PR via gh.
    (
      cd "$_fix_worktree"
      git add -A 2>/dev/null
      if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "fix: end-of-batch test regression

Auto-fix from sharkrite end-of-batch verification phase.

Batch merges:
${_batch_merges:-(none)}" 2>/dev/null || true
      fi
      git push origin "$_fix_branch" 2>/dev/null || true
    )
    local _eob_pr
    _eob_pr=$(gh pr create \
      --title "fix(batch): end-of-batch test regression" \
      --label "priority-critical" \
      --body "Auto-generated by sharkrite end-of-batch verification.

The cumulative state of main after the batch's squash merges had test failures. This PR contains the auto-fix.

## Batch merges
${_batch_merges:-(none completed)}

## Verification
Tests pass on this branch after the auto-fix." \
      --head "$_fix_branch" \
      --base main 2>/dev/null | grep -oE 'pull/[0-9]+' | sed 's|pull/||' | head -1 || true)
    if [ -n "$_eob_pr" ]; then
      print_success "Hotfix PR opened: #$_eob_pr"
      EOB_FIX_PR="$_eob_pr"
      EOB_RESULT="fixed"
    else
      print_warning "Hotfix branch pushed but PR creation failed — branch is at: $_fix_branch"
      EOB_RESULT="fixed-no-pr"
    fi
  else
    print_error "End-of-batch fix loop exhausted ($_max_attempts attempts) — manual intervention required"
    # Leave the worktree + branch in place. Surface as fix-main issue.
    local _existing_fix_main
    _existing_fix_main=$(gh issue list --label "fix-main" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [ -z "$_existing_fix_main" ] || [ "$_existing_fix_main" = "null" ]; then
      gh label create "fix-main" --color "B60205" --description "Test suite failures on main branch" 2>/dev/null || true
      _existing_fix_main=$(gh issue create \
        --title "[fix-main] End-of-batch test failures (auto-fix exhausted $_max_attempts attempts)" \
        --label "fix-main" \
        --body "Sharkrite's end-of-batch verification ran the full suite after this batch and found failures the auto-fix loop could not resolve.

## Batch merges
${_batch_merges:-(none completed)}

## Failure tail
\`\`\`
$(tail -120 "$_output")
\`\`\`

## Recovery worktree
A worktree with the partial fix attempts is at: \`$_fix_worktree\`
Branch: \`$_fix_branch\`

## Acceptance Criteria
- [ ] Identify the regression
- [ ] Fix it (do not revert batch merges)
- [ ] Tests pass on main" \
        2>/dev/null | grep -oE '/issues/[0-9]+' | sed 's|/issues/||' | head -1 || echo "")
    fi
    EOB_RESULT="failed-manual"
  fi

  rm -f "$_output"
}

# Record a run to the persistent history file
record_run() {
  local issue="$1" mode="$2"
  local history_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/run-history.log"
  mkdir -p "$(dirname "$history_file")"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $issue $mode" >> "$history_file"
}

# Batch processing requires associative arrays (bash 4+)
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "$BASH" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: Batch processing requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  print_error "jq required: brew install jq"
  exit 1
fi

# Parse arguments
ISSUE_LIST=()
FILTER_TYPE=""
FILTER_VALUE=""
SMART_WAIT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --smart-wait)
      SMART_WAIT=true
      shift
      ;;
    --label)
      FILTER_TYPE="label"
      FILTER_VALUE="$2"
      shift 2
      ;;
    --milestone)
      FILTER_TYPE="milestone"
      FILTER_VALUE="$2"
      shift 2
      ;;
    --state)
      FILTER_TYPE="state"
      FILTER_VALUE="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_LIST+=("$1")
      fi
      shift
      ;;
  esac
done

# Fetch issues if filter specified
if [ -n "$FILTER_TYPE" ]; then
  print_header "📋 Fetching Issues with Filter"
  print_info "Filter: $FILTER_TYPE = $FILTER_VALUE"

  case "$FILTER_TYPE" in
    label)
      FETCHED_ISSUES=$(gh issue list --label "$FILTER_VALUE" --state open --json number --jq '.[].number' | sort -n | tr '\n' ' ')
      ;;
    milestone)
      FETCHED_ISSUES=$(gh issue list --milestone "$FILTER_VALUE" --state open --json number --jq '.[].number' | sort -n | tr '\n' ' ')
      ;;
    state)
      FETCHED_ISSUES=$(gh issue list --state "$FILTER_VALUE" --json number --jq '.[].number' | sort -n | tr '\n' ' ')
      ;;
  esac

  # Convert to array
  read -ra ISSUE_LIST <<< "$FETCHED_ISSUES"

  print_success "Found ${#ISSUE_LIST[@]} issues"
  echo "Issues: ${ISSUE_LIST[*]}"
  echo ""
fi

# Validate we have issues to process
if [ ${#ISSUE_LIST[@]} -eq 0 ]; then
  print_error "No issues specified"
  echo ""
  echo "Usage:"
  echo "  rite 19 21 31 32              # Process specific issues"
  echo "  rite --label bug              # Process all issues with label"
  echo "  rite --milestone v1.0         # Process all issues in milestone"
  echo ""
  exit 1
fi

# Initialize session tracking
init_session "batch-${ISSUE_LIST[0]}-$(date +%s)"

# Batch processing state
BATCH_START_TIME=$(date +%s)
TOTAL_ISSUES=${#ISSUE_LIST[@]}
COMPLETED_ISSUES=0
FAILED_ISSUES=()
BLOCKED_ISSUES=()
SKIPPED_ISSUES=()

# Per-issue tracking (associative arrays, requires bash 4+)
declare -A ISSUE_STATUS
declare -A ISSUE_TIME
declare -A ISSUE_PR
declare -A ISSUE_BRANCH
declare -A PR_CHANGES

# Summary arrays
SECURITY_UPDATES=()
NEW_ISSUES_CREATED=()
FAILED_PAIRS=()

# Pre-start checks
print_info "Running pre-start checks..."

# AWS credential check — warn only, don't block. If creds are actually needed,
# tests will fail (which IS a hard gate).
if detect_aws_project && ! detect_credentials_expired; then
  print_warning "AWS credentials expired — run: aws sso login --profile ${RITE_AWS_PROFILE}"
fi

# Filter out issues that are actively running in another process.
_all_procs=$(ps -eo pid,command 2>/dev/null || true)
_active_matches=$(echo "$_all_procs" | grep -E "(workflow-runner|claude-workflow)\.sh" | grep -v "grep" || true)
_filtered_list=()
_active_skipped=()
for _issue_num in "${ISSUE_LIST[@]}"; do
  if echo "$_active_matches" | grep -qE " ${_issue_num}( |$)"; then
    _active_skipped+=("$_issue_num")
  else
    _filtered_list+=("$_issue_num")
  fi
done
if [ ${#_active_skipped[@]} -gt 0 ]; then
  print_warning "Skipping issues already running: ${_active_skipped[*]}"
  ISSUE_LIST=("${_filtered_list[@]}")
  TOTAL_ISSUES=${#ISSUE_LIST[@]}
fi

# Prioritize fix-main issues: if main is broken, fix it first before other issues
# waste cycles hitting the same wall. Prepend any open fix-main issues to the queue.
_fix_main_issues=$(gh issue list --label "fix-main" --state open --json number --jq '.[].number' 2>/dev/null || true)
if [ -n "$_fix_main_issues" ]; then
  _prepend=()
  while IFS= read -r _fmi; do
    [ -z "$_fmi" ] && continue
    _already_queued=false
    for _existing in "${ISSUE_LIST[@]}"; do
      [ "$_existing" = "$_fmi" ] && _already_queued=true && break
    done
    [ "$_already_queued" = false ] && _prepend+=("$_fmi")
  done <<< "$_fix_main_issues"
  if [ ${#_prepend[@]} -gt 0 ]; then
    ISSUE_LIST=("${_prepend[@]}" "${ISSUE_LIST[@]}")
    TOTAL_ISSUES=${#ISSUE_LIST[@]}
    print_info "Prioritized ${#_prepend[@]} fix-main issue(s): ${_prepend[*]}"
  fi
fi

# Check session limits upfront
SESSION_STATE=$(get_session_info)
ISSUES_COMPLETED=$(echo "$SESSION_STATE" | jq -r '.issues_completed')
SESSION_START=$(echo "$SESSION_STATE" | jq -r '.start_time')
CURRENT_TIME=$(date +%s)
ELAPSED_HOURS=$(awk "BEGIN {print ($CURRENT_TIME - $SESSION_START) / 3600}")

# Validate batch won't exceed limits
PROJECTED_TOTAL=$((ISSUES_COMPLETED + TOTAL_ISSUES))
MAX_ISSUES_LIMIT="${RITE_MAX_ISSUES_PER_SESSION:-8}"

if [ "$PROJECTED_TOTAL" -gt "$MAX_ISSUES_LIMIT" ]; then
  print_warning "Batch would exceed session limit ($MAX_ISSUES_LIMIT issues)"
  print_info "Current: $ISSUES_COMPLETED issues completed"
  print_info "Batch size: $TOTAL_ISSUES issues"
  print_info "Projected: $PROJECTED_TOTAL issues total"
  echo ""

  # Calculate how many we can do
  ALLOWED_ISSUES=$((MAX_ISSUES_LIMIT - ISSUES_COMPLETED))

  if [ "$ALLOWED_ISSUES" -le 0 ]; then
    print_error "Session limit already reached"
    print_info "Start new session to continue"
    exit 1
  fi

  SKIPPED_BY_LIMIT=("${ISSUE_LIST[@]:$ALLOWED_ISSUES}")
  ISSUE_LIST=("${ISSUE_LIST[@]:0:$ALLOWED_ISSUES}")
  TOTAL_ISSUES=${#ISSUE_LIST[@]}
  print_warning "Limiting batch to $ALLOWED_ISSUES issues: ${ISSUE_LIST[*]}"
  print_info "Deferred to next session: ${SKIPPED_BY_LIMIT[*]}"
  echo ""
fi

print_success "Pre-start checks passed"
echo ""

print_header "🚀 Batch Processing Started"
echo "Issues: ${ISSUE_LIST[*]} ($TOTAL_ISSUES total)"
echo "Mode: Unsupervised (--auto)"
echo ""

# Pre-flight blocker scan: Check all issues for potential blockers upfront
print_header "🔍 Pre-Flight Blocker Scan"
print_info "Scanning all issues for potential blockers before starting..."
echo ""

PREFLIGHT_BLOCKERS=()
PREFLIGHT_BLOCKER_MSGS=()

for ISSUE_NUM in "${ISSUE_LIST[@]}"; do
  # Check if issue has an open PR (use shared detection for accurate body-based matching)
  PR_NUMBER=""
  detect_pr_for_issue "$ISSUE_NUM" 2>/dev/null || true

  if [ -n "$PR_NUMBER" ]; then
    print_info "Issue #$ISSUE_NUM has PR #$PR_NUMBER - checking for blockers..."

    # Run blocker checks (pass "unsupervised" since this is batch mode)
    BLOCKER_CHECK=$(check_blockers "pre-merge" "$PR_NUMBER" "$ISSUE_NUM" "unsupervised" 2>&1) || {
      BLOCKER_FOUND=true
      # Extract blocker type from check_blockers output
      BLOCKER_TYPE=$(echo "$BLOCKER_CHECK" | grep -o "BLOCKER:.*" | head -1 || echo "Unknown blocker")
      PREFLIGHT_BLOCKERS+=("$ISSUE_NUM")
      PREFLIGHT_BLOCKER_MSGS+=("$BLOCKER_TYPE (PR #$PR_NUMBER)")
      print_warning "⚠️  Issue #$ISSUE_NUM: $BLOCKER_TYPE"
    }
  fi
done

if [ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]; then
  echo ""
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_warning "Pre-Flight Blockers Detected"
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  print_info "The following issues have potential blockers:"
  echo ""

  for i in "${!PREFLIGHT_BLOCKERS[@]}"; do
    echo "  • Issue #${PREFLIGHT_BLOCKERS[$i]}: ${PREFLIGHT_BLOCKER_MSGS[$i]}"
  done

  echo ""
  print_info "These issues will be deferred during batch processing"
  print_info "Workflow will continue with non-blocked issues"
  echo ""
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
else
  print_success "No blockers detected in pre-flight scan"
  echo ""
fi

# Send batch start notification
send_notification_all "🚀 *Batch Processing Started*
*Total Issues:* $TOTAL_ISSUES
*Issues:* ${ISSUE_LIST[*]}
*Pre-flight Blockers:* ${#PREFLIGHT_BLOCKERS[@]}
*Mode:* Unsupervised" "normal"

# Process each issue
for ISSUE_NUM in "${ISSUE_LIST[@]}"; do
  ISSUE_START_TIME=$(date +%s)
  CURRENT_ISSUE=$((COMPLETED_ISSUES + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]} + ${#SKIPPED_ISSUES[@]} + 1))

  print_header "📌 Processing Issue #$ISSUE_NUM ($CURRENT_ISSUE/$TOTAL_ISSUES)"
  record_run "$ISSUE_NUM" "batch"

  # Fetch issue details. Use gh_safe to distinguish a real 404 (issue does
  # not exist) from a transient gh failure (rate limit, network, 5xx). The
  # previous `gh ... 2>/dev/null || echo "{}"` pattern routed both through
  # the same "not_found" branch — on 2026-05-26 a rate limit after #4's busy
  # run silently skipped issues #8/#9/#10 as "not found" when they were OPEN.
  #
  # if-guard pattern is required for two reasons:
  #   1. `var=$(...)` under `set -e` exits the script on non-zero substitution.
  #   2. `if cmd; then ...; else $?` works; `if ! cmd; then $?` does NOT —
  #      the `!` negation consumes the original exit code (always becomes 0).
  if ISSUE_DETAILS=$(gh_safe "fetch issue #$ISSUE_NUM" issue view "$ISSUE_NUM" --json title,labels,state); then
    _fetch_exit=0
  else
    _fetch_exit=$?
  fi

  if [ "$_fetch_exit" -eq 4 ]; then
    print_error "Issue #$ISSUE_NUM not found (HTTP 404)"
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="not_found"
    continue
  elif [ "$_fetch_exit" -ne 0 ]; then
    print_error "Issue #$ISSUE_NUM — gh call failed (likely transient: rate limit / network)"
    print_info "Skipping rather than guessing state. Re-run the batch after the rate limit clears."
    FAILED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="fetch_failed"
    continue
  fi

  ISSUE_TITLE=$(echo "$ISSUE_DETAILS" | jq -r '.title')
  ISSUE_STATE=$(echo "$ISSUE_DETAILS" | jq -r '.state')

  print_info "Title: $ISSUE_TITLE"
  print_info "State: $ISSUE_STATE"
  echo ""

  # Skip if not open (catches CLOSED, MERGED, and any other non-open state)
  # But still clean up dangling artifacts (worktrees, branches, session state)
  # same as single-issue mode in workflow-runner.sh
  if [ "$ISSUE_STATE" != "OPEN" ]; then
    print_success "Issue is $ISSUE_STATE - cleaning up artifacts"

    # Find the PR branch for this issue (search closed PRs)
    _pr_branch=""
    _issue_data=$(gh issue view "$ISSUE_NUM" --json closedByPullRequestsReferences 2>/dev/null || echo "{}")
    _pr_number=$(echo "$_issue_data" | jq -r '.closedByPullRequestsReferences[0].number // empty' | head -1)

    if [ -n "${_pr_number:-}" ]; then
      _pr_branch=$(gh pr view "$_pr_number" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
    fi

    # Fallback: search closed PRs for "Closes #N"
    if [ -z "${_pr_branch:-}" ]; then
      _closed_pr=$(gh pr list --state closed --json number,body --limit 50 2>/dev/null | \
        jq --arg issue "$ISSUE_NUM" -r \
        '.[] | select(.body != null) | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .number' | \
        head -1 || true)
      if [ -n "${_closed_pr:-}" ]; then
        _pr_branch=$(gh pr view "$_closed_pr" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
      fi
    fi

    _cleaned_anything=false

    if [ -n "${_pr_branch:-}" ]; then
      # 1. Remove worktree if it exists for this branch
      _wt_path=$(git worktree list | grep "\[$_pr_branch\]" | awk '{print $1}' || true)
      if [ -n "${_wt_path:-}" ]; then
        if git worktree remove "$_wt_path" --force 2>/dev/null; then
          [ "$_cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && _cleaned_anything=true
          echo -e "${GREEN}  ✓ Removed worktree: $(basename "$_wt_path")${NC}"
        fi
      fi

      # 2. Delete local branch if it still exists
      if git show-ref --verify --quiet "refs/heads/$_pr_branch" 2>/dev/null; then
        if git branch -D "$_pr_branch" >/dev/null 2>&1; then
          [ "$_cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && _cleaned_anything=true
          echo -e "${GREEN}  ✓ Deleted local branch: $_pr_branch${NC}"
        fi
      fi

      # 3. Delete remote branch if it still exists
      if git ls-remote --heads origin "$_pr_branch" 2>/dev/null | grep -q "$_pr_branch"; then
        if git push origin --delete "$_pr_branch" 2>/dev/null; then
          [ "$_cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && _cleaned_anything=true
          echo -e "${GREEN}  ✓ Deleted remote branch: origin/$_pr_branch${NC}"
        fi
      fi
    fi

    # 4. Remove session state file for this issue
    _state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/session-state-${ISSUE_NUM}.json"
    if [ -f "$_state_file" ]; then
      rm -f "$_state_file"
      [ "$_cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && _cleaned_anything=true
      print_success "Removed session state: session-state-${ISSUE_NUM}.json"
    fi

    if [ "$_cleaned_anything" = false ]; then
      print_info "No dangling artifacts found"
    fi

    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="already_closed"
    echo ""
    continue
  fi

  # Check if this is a follow-up issue with parent PR dependency
  ISSUE_BODY=$(gh issue view "$ISSUE_NUM" --json body --jq '.body' 2>/dev/null || echo "")
  PARENT_PR=""

  if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
    # Extract parent PR number from body marker
    PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2)

    if [ -n "$PARENT_PR" ]; then
      # Check if parent PR is still open
      PARENT_PR_STATE=$(gh pr view "$PARENT_PR" --json state --jq '.state' 2>/dev/null || echo "")

      if [ "$PARENT_PR_STATE" = "OPEN" ]; then
        # Check if parent issue is also in this batch (deliberate pairing)
        PARENT_ISSUE=$(gh pr view "$PARENT_PR" --json body --jq '.body' 2>/dev/null | grep -oE 'Closes #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")

        # Check if parent issue is in our queue
        PARENT_IN_QUEUE=false
        for queued_issue in "${ISSUE_LIST[@]}"; do
          if [ "$queued_issue" = "$PARENT_ISSUE" ]; then
            PARENT_IN_QUEUE=true
            break
          fi
        done

        if [ "$PARENT_IN_QUEUE" = true ]; then
          print_success "✅ Parent issue #$PARENT_ISSUE is in queue - this is a follow-up pair"
          print_info "Follow-up work will update parent PR #$PARENT_PR before merging parent issue"
        else
          # Parent not in queue, defer this issue
          print_warning "⏸️  Parent PR #$PARENT_PR is still open - deferring issue #$ISSUE_NUM"
          print_info "This follow-up issue will be processed after parent PR merges"
          SKIPPED_ISSUES+=("$ISSUE_NUM")
          ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"
          echo ""
          continue
        fi
      elif [ "$PARENT_PR_STATE" = "MERGED" ]; then
        print_success "✅ Parent PR #$PARENT_PR is merged - proceeding with follow-up"
      fi
    fi
  fi

  # Check if issue depends on another issue that failed/was skipped in this batch
  # Parses "After: #N", "After #N", "Depends on #N" patterns from issue body
  DEP_ISSUES=$(echo "$ISSUE_BODY" | grep -oiE '(After:? #|Depends on #|Blocked by:? #)[0-9]+' | grep -oE '[0-9]+' || true)
  if [ -n "$DEP_ISSUES" ]; then
    DEP_FAILED=false
    FAILED_DEP=""
    DEP_REASON=""
    for dep_num in $DEP_ISSUES; do
      dep_status="${ISSUE_STATUS[$dep_num]:-}"
      if [ "$dep_status" = "failed" ] || [ "$dep_status" = "blocked" ] || [ "$dep_status" = "not_found" ] || [ "$dep_status" = "dep_failed" ] || [ "$dep_status" = "fetch_failed" ]; then
        DEP_FAILED=true
        FAILED_DEP="$dep_num"
        DEP_REASON="$dep_status in this batch"
        break
      fi
      # Also check if dep issue is still open with an unmerged PR
      dep_issue_state=$(gh issue view "$dep_num" --json state --jq '.state' 2>/dev/null || echo "")
      if [ "$dep_issue_state" = "OPEN" ]; then
        DEP_FAILED=true
        FAILED_DEP="$dep_num"
        DEP_REASON="issue still open (PR not merged)"
        break
      fi
      # Closed-but-empty: dep's PR may have merged with zero file changes
      # (truncated worker session, or work landed in a sibling worktree).
      # Treat that as unsatisfied — downstream issues that depend on it would
      # otherwise inherit the gap and either re-implement the upstream work or
      # fail confusingly. Inspect the most recent closed PR for this issue.
      _dep_pr_stats=$(gh pr list --search "Closes #${dep_num} OR closes #${dep_num} in:body" --state closed --json number,additions,deletions,changedFiles --jq 'sort_by(.number) | reverse | .[0]' 2>/dev/null || echo "")
      if [ -n "$_dep_pr_stats" ] && [ "$_dep_pr_stats" != "null" ]; then
        _dep_changed=$(echo "$_dep_pr_stats" | jq -r '.changedFiles // 0')
        _dep_adds=$(echo "$_dep_pr_stats" | jq -r '.additions // 0')
        if [ "$_dep_changed" -eq 0 ] && [ "$_dep_adds" -eq 0 ]; then
          DEP_FAILED=true
          FAILED_DEP="$dep_num"
          DEP_REASON="dep PR merged empty (zero file changes)"
          break
        fi
      fi
    done
    if [ "$DEP_FAILED" = true ]; then
      print_warning "Dependency #$FAILED_DEP not ready (${DEP_REASON:-unknown}) — skipping issue #$ISSUE_NUM"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="dep_failed"
      echo ""
      continue
    fi
  fi

  # Check if issue is actively being worked on (worktree exists with a running rite/claude process)
  _active_wt=""
  if detect_pr_for_issue "$ISSUE_NUM" 2>/dev/null; then
    detect_worktree_for_pr "$PR_NUMBER" 2>/dev/null || true
    _active_wt="${WORKTREE_PATH:-}"
  fi
  if [ -z "$_active_wt" ]; then
    _main_wt=$(git rev-parse --show-toplevel)
    _active_wt=$(git worktree list | awk '{print $1}' | grep -v "^${_main_wt}$" | \
      grep -E "(issue.?${ISSUE_NUM}|#${ISSUE_NUM}|[-_]${ISSUE_NUM}[-_]|[-_]${ISSUE_NUM}$)" | head -1 || true)
  fi
  if [ -n "$_active_wt" ]; then
    # Check if a rite or claude process is running for this issue
    _loop_procs=$(ps -eo pid,command 2>/dev/null || true)
    if echo "$_loop_procs" | grep -qE "workflow-runner\.sh ${ISSUE_NUM}( |$)" || \
       echo "$_loop_procs" | grep -qE "claude-workflow\.sh ${ISSUE_NUM}( |$)"; then
      print_warning "Issue #$ISSUE_NUM is actively running in another process — skipping"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="active"
      echo ""
      continue
    fi
  fi
  # Reset PR_NUMBER — detect_pr_for_issue sets it globally
  PR_NUMBER=""
  WORKTREE_PATH=""

  # Check if issue already has open PR (must have "Closes #XX" in body)
  EXISTING_PR=""
  for pr_num in $(gh pr list --state open --json number --jq '.[].number' 2>/dev/null); do
    if gh pr view "$pr_num" --json body --jq '.body' 2>/dev/null | grep -q "Closes #${ISSUE_NUM}\$\|Closes #${ISSUE_NUM}[^0-9]"; then
      EXISTING_PR="$pr_num"
      break
    fi
  done

  if [ -n "$EXISTING_PR" ]; then
    # If smart-wait enabled and this looks like a parent issue, wait for review
    if [ "$SMART_WAIT" = true ]; then
      # Check if this issue's PR was just updated by a previous issue in batch
      get_latest_work_commit_time "" "$EXISTING_PR"
      PR_UPDATED="$LATEST_COMMIT_TIME"
      REVIEW_TIME=$(gh pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt' 2>/dev/null || echo "")

      if [ -n "$PR_UPDATED" ] && [ -n "$REVIEW_TIME" ] && [[ "$PR_UPDATED" > "$REVIEW_TIME" ]]; then
        print_info "⏰ Smart Wait: issue #$ISSUE_NUM updated after review"
        print_info "Waiting for new review (timeout: 15 minutes, poll every 2 min)..."
        echo ""

        WAIT_START=$(date +%s)
        MAX_WAIT=$((15 * 60))  # 15 minutes
        POLL_INTERVAL=120       # 2 minutes

        while true; do
          sleep $POLL_INTERVAL

          # Check for newer review
          NEW_REVIEW_TIME=$(gh pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt' 2>/dev/null || echo "")

          if [ -n "$NEW_REVIEW_TIME" ] && [[ "$NEW_REVIEW_TIME" > "$PR_UPDATED" ]]; then
            print_success "✅ New review detected! Continuing with merge workflow..."
            echo ""
            break
          fi

          ELAPSED=$(($(date +%s) - WAIT_START))
          if [ $ELAPSED -ge $MAX_WAIT ]; then
            print_warning "⏱️  Timeout: No review after 15 minutes"

            # Send Slack notification
            send_notification "⏱️ Manual Intervention Needed" "Issue #$ISSUE_NUM: PR #$EXISTING_PR timeout waiting for review. Run: \`rite $ISSUE_NUM\`" "warning"

            print_info "📱 Slack notification sent"
            print_info "Manual run needed: rite $ISSUE_NUM"
            echo ""

            SKIPPED_ISSUES+=("$ISSUE_NUM")
            ISSUE_STATUS["$ISSUE_NUM"]="review_timeout"
            ISSUE_PR["$ISSUE_NUM"]="$EXISTING_PR"
            continue 2  # Skip to next issue in outer loop
          fi

          print_info "Still waiting... ($((ELAPSED / 60))/$((MAX_WAIT / 60)) min)"
        done
      fi
    fi

    # Check if we're already in this PR's branch (avoid conflicts)
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    PR_BRANCH=$(gh pr view "$EXISTING_PR" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$PR_BRANCH" ] && [ "$CURRENT_BRANCH" = "$PR_BRANCH" ]; then
      print_warning "Already in this issue's branch ($PR_BRANCH) - skipping to avoid conflicts"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="in_current_branch"
      ISSUE_PR["$ISSUE_NUM"]="$EXISTING_PR"
      echo ""
      continue
    fi

    # Otherwise, proceed - workflow will use worktree for this PR's branch
    print_info "Will continue work on issue #$ISSUE_NUM in worktree"
    echo ""
  fi

  # Run workflow in unsupervised mode
  print_info "Starting workflow-runner.sh --auto..."
  echo ""

  # Export BATCH_MODE flag so nested scripts know we're in batch processing
  export BATCH_MODE=true
  # Export full issue list so nested scripts (e.g., merge cleanup) can protect sibling worktrees
  export BATCH_ISSUE_LIST="${ISSUE_LIST[*]}"

  # Run workflow with exit code handling
  if "$RITE_LIB_DIR/core/workflow-runner.sh" "$ISSUE_NUM" --unsupervised; then
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    # Get PR number for this issue (search by body text, most recent first)
    PR_NUMBER=$(gh pr list --search "fixes #${ISSUE_NUM} OR closes #${ISSUE_NUM} in:body" --state all --json number --jq 'sort_by(.number) | reverse | .[0].number' 2>/dev/null || echo "")

    print_success "Issue #$ISSUE_NUM completed successfully"
    if [ -n "$PR_NUMBER" ]; then
      print_info "PR: #$PR_NUMBER"
      ISSUE_PR["$ISSUE_NUM"]="$PR_NUMBER"

      # Capture branch name and changes summary
      BRANCH_NAME=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
      if [ -n "$BRANCH_NAME" ]; then
        ISSUE_BRANCH["$ISSUE_NUM"]="$BRANCH_NAME"
      fi

      # Capture changes summary (files changed + lines)
      PR_STATS=$(gh pr view "$PR_NUMBER" --json additions,deletions,changedFiles --jq '"\(.changedFiles) files, +\(.additions)/-\(.deletions) lines"' 2>/dev/null || echo "")
      if [ -n "$PR_STATS" ]; then
        PR_CHANGES["$PR_NUMBER"]="$PR_STATS"
      fi

      # Check for security doc updates
      SECURITY_DOC_UPDATED=$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null | grep -c "docs/security/DEVELOPMENT-GUIDE.md" || true)
      if [ "$SECURITY_DOC_UPDATED" -gt 0 ]; then
        SECURITY_UPDATES+=("PR #$PR_NUMBER: Updated DEVELOPMENT-GUIDE.md with findings from #$ISSUE_NUM")
      fi

      # Check for new tech-debt issues created
      NEW_DEBT_ISSUE=$(gh issue list --label "tech-debt" --state open --search "sharkrite-parent-pr:$PR_NUMBER in:body" --json number --jq '.[0].number' 2>/dev/null || echo "")
      if [ -n "$NEW_DEBT_ISSUE" ]; then
        NEW_ISSUES_CREATED+=("Issue #$NEW_DEBT_ISSUE (from PR #$PR_NUMBER)")
      fi
    fi
    print_info "Duration: ${ISSUE_DURATION}s"
    echo ""

    COMPLETED_ISSUES=$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS["$ISSUE_NUM"]="completed"

    # Send success notification if smart-wait was used (means auto-merge happened)
    if [ "$SMART_WAIT" = true ] && [ -n "$PR_NUMBER" ]; then
      send_notification "✅ Auto-Merge Success!" "Issue #$ISSUE_NUM completed and PR #$PR_NUMBER merged automatically! Duration: $((ISSUE_DURATION / 60))m" "success"
    fi

  else
    EXIT_CODE=$?
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_error "Issue #$ISSUE_NUM failed (exit code: $EXIT_CODE)"
    print_info "Duration: ${ISSUE_DURATION}s"
    echo ""

    if [ $EXIT_CODE -eq 5 ]; then
      # Usage cap / batch-blocking blocker — stop entire batch immediately
      print_error "Batch-blocking failure (exit 5) — stopping batch"
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="failed"
      break

    elif [ $EXIT_CODE -eq 10 ]; then
      # Blocker detected - defer instead of stopping
      print_warning "⏸️  Blocker detected - deferring issue #$ISSUE_NUM"
      BLOCKED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="blocked"

      # Send blocker notification
      send_blocker_notification "Workflow Blocker" "$ISSUE_NUM"

      print_info "Will retry after processing remaining issues"
      echo ""
      # Continue with next issue instead of breaking

    else
      # Other failure
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="failed"
    fi
  fi

  # Check session limits after each issue
  SESSION_STATE=$(get_session_info)
  ISSUES_COMPLETED=$(echo "$SESSION_STATE" | jq -r '.issues_completed')

  if [ "$ISSUES_COMPLETED" -ge "$MAX_ISSUES_LIMIT" ]; then
    print_warning "Session limit reached ($MAX_ISSUES_LIMIT issues)"
    print_info "Stopping batch processing"
    break
  fi

  # Small delay between issues (avoid rate limiting)
  if [ "$CURRENT_ISSUE" -lt "$TOTAL_ISSUES" ]; then
    print_info "Waiting 5s before next issue..."
    sleep 5
    echo ""
  fi
done

# End-of-batch verification phase. Always runs, regardless of how many issues
# passed/failed/blocked (its job is to validate main's state, not per-issue
# success). Sets EOB_RESULT and EOB_FIX_PR.
EOB_RESULT="not-run"
EOB_FIX_PR=""
if [ "$COMPLETED_ISSUES" -gt 0 ]; then
  # Only meaningful when at least one issue actually merged something.
  set +e
  _run_end_of_batch_verification
  set -e
fi

# Calculate final stats
BATCH_END_TIME=$(date +%s)
TOTAL_DURATION=$((BATCH_END_TIME - BATCH_START_TIME))
TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))

# Generate summary report
# Retry blocked issues (they may have follow-up issues created now)
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  print_header "🔄 Retrying Previously Blocked Issues"

  echo "Found ${#BLOCKED_ISSUES[@]} blocked issue(s) - checking if follow-ups were created..."
  echo ""

  RETRY_SUCCESS=()
  STILL_BLOCKED=()

  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    # Check if follow-up issue was created for this blocker
    FOLLOWUP_ISSUE=$(gh issue list --search "parent-pr in:body in:title" --label "review-follow-up" --state open --json number,body --jq ".[] | select(.body | contains(\"#$ISSUE_NUM\")) | .number" 2>/dev/null | head -1 || echo "")

    if [ -n "$FOLLOWUP_ISSUE" ]; then
      print_info "Issue #$ISSUE_NUM blocked → Follow-up #$FOLLOWUP_ISSUE created"
      print_success "No retry needed - workflow created follow-up issue"
      RETRY_SUCCESS+=("$ISSUE_NUM")
    else
      print_warning "Issue #$ISSUE_NUM still blocked (no follow-up created)"
      STILL_BLOCKED+=("$ISSUE_NUM")
    fi
    echo ""
  done

  # Update blocked list to only include still-blocked items
  BLOCKED_ISSUES=("${STILL_BLOCKED[@]}")
fi

print_header "📊 Batch Processing Summary"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Overall Statistics"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total Issues:     $TOTAL_ISSUES"
echo "Processed:        $TOTAL_PROCESSED"
echo "Completed:        $COMPLETED_ISSUES"
echo "Failed:           ${#FAILED_ISSUES[@]}"
echo "Blocked:          ${#BLOCKED_ISSUES[@]}"
echo "Skipped:          ${#SKIPPED_ISSUES[@]}"
echo "Total Duration:   ${TOTAL_DURATION}s ($((TOTAL_DURATION / 60))m)"
case "${EOB_RESULT:-not-run}" in
  passed)              echo "End-of-batch:     ✅ full suite passed" ;;
  fixed)               echo "End-of-batch:     🔧 auto-fixed → hotfix PR #${EOB_FIX_PR:-?}" ;;
  fixed-no-pr)         echo "End-of-batch:    🔧 auto-fixed but PR creation failed" ;;
  failed-manual)       echo "End-of-batch:     ❌ failed — manual intervention (see fix-main issue)" ;;
  failed-no-worktree)  echo "End-of-batch:     ❌ could not create fix worktree" ;;
  skipped*)            echo "End-of-batch:     ⏭️  skipped (${EOB_RESULT#skipped-})" ;;
  not-run)             echo "End-of-batch:     ⏭️  not run (no issues completed)" ;;
  *)                   echo "End-of-batch:     ${EOB_RESULT}" ;;
esac
echo ""

# Detailed issue breakdown
if [ $COMPLETED_ISSUES -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Completed Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$ISSUE_NUM]}" = "completed" ]; then
      DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
      PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
      echo "  ✅ Issue #$ISSUE_NUM → PR #$PR_NUM (${DURATION}s)"
    fi
  done | sort -t'#' -k2 -n
  echo ""
fi

if [ ${#FAILED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Failed Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${FAILED_ISSUES[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    echo "  ❌ Issue #$ISSUE_NUM (${DURATION}s)"
  done
  echo ""
fi

if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Still Blocked Issues (Manual Intervention Needed)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    echo "  🚨 Issue #$ISSUE_NUM (${DURATION}s)"
  done
  echo ""
  print_warning "These issues require manual review - no follow-up was created"
  echo ""
fi

if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Skipped Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${SKIPPED_ISSUES[@]}"; do
    REASON=${ISSUE_STATUS[$ISSUE_NUM]:-"unknown"}
    echo "  ⏭️  Issue #$ISSUE_NUM ($REASON)"
  done
  echo ""
fi

# Build comprehensive Slack summary
NOTIFICATION_MESSAGE="📊 *Batch Processing Complete*

*Overall Statistics:*
• Total Issues: $TOTAL_ISSUES
• Completed: $COMPLETED_ISSUES ✅
• Failed: ${#FAILED_ISSUES[@]} ❌
• Blocked: ${#BLOCKED_ISSUES[@]} 🚨
• Skipped: ${#SKIPPED_ISSUES[@]} ⏭️
• Duration: $((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s
• Success Rate: $((COMPLETED_ISSUES * 100 / TOTAL_ISSUES))%"

# Add merged branches section
if [ $COMPLETED_ISSUES -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*🌿 Merged Branches:*"
  for ISSUE_NUM in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$ISSUE_NUM]}" = "completed" ]; then
      PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-""}
      BRANCH=${ISSUE_BRANCH[$ISSUE_NUM]:-"unknown"}
      CHANGES="N/A"
      [ -n "$PR_NUM" ] && CHANGES=${PR_CHANGES[$PR_NUM]:-"N/A"}
      NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• \`$BRANCH\` → PR #$PR_NUM ($CHANGES)"
    fi
  done | sort -t'#' -k2 -n
fi

# Add security doc updates section
if [ ${#SECURITY_UPDATES[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*🔒 Security Doc Updates:*"
  for update in "${SECURITY_UPDATES[@]}"; do
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• $update"
  done
fi

# Add new issues created section
if [ ${#NEW_ISSUES_CREATED[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*📝 New \`tech-debt\` Issues:*"
  for issue in "${NEW_ISSUES_CREATED[@]}"; do
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• $issue"
  done
fi

# Add failed pairs section (needs manual restart)
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*⚠️  Failed Pairs (Manual Restart Needed):*"
  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• Issue #$ISSUE_NUM (PR #$PR_NUM) - Run: \`rite $ISSUE_NUM\`"
  done
fi

# Add session stats
SESSION_STATE=$(get_session_info)
TOTAL_TOKENS=$(echo "$SESSION_STATE" | jq -r '.tokens_used // 0')
SESSION_DURATION=$(echo "$SESSION_STATE" | jq -r '.session_start // 0')
if [ "$SESSION_DURATION" != "0" ]; then
  SESSION_ELAPSED=$(( $(date +%s) - SESSION_DURATION ))
  SESSION_HOURS=$(( SESSION_ELAPSED / 3600 ))
  SESSION_MINS=$(( (SESSION_ELAPSED % 3600) / 60 ))

  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*📈 Session Stats:*
• Total Time: ${SESSION_HOURS}h ${SESSION_MINS}m
• Issues Processed: $(echo "$SESSION_STATE" | jq -r '.issues_completed // 0')
• Approx Tokens: $TOTAL_TOKENS"
fi

send_notification_all "$NOTIFICATION_MESSAGE" "normal"

# Exit with appropriate code
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  print_warning "Batch paused due to blocker"
  exit 10
elif [ ${#FAILED_ISSUES[@]} -gt 0 ] && [ $COMPLETED_ISSUES -eq 0 ]; then
  print_error "All issues failed"
  exit 1
elif [ $COMPLETED_ISSUES -eq 0 ]; then
  print_warning "No issues completed"
  exit 0
else
  print_success "Batch processing completed"
  exit 0
fi

# Helper function: Create batch resume script
create_batch_resume_script() {
  local blocked_issue="$1"
  shift
  local remaining_issues=("$@")

  # Filter out already processed issues
  local resume_list=()
  local found_blocked=false

  for issue in "${remaining_issues[@]}"; do
    if [ "$found_blocked" = true ]; then
      resume_list+=("$issue")
    fi

    if [ "$issue" = "$blocked_issue" ]; then
      found_blocked=true
      resume_list+=("$issue")  # Include blocked issue for retry
    fi
  done

  # Create resume directory
  mkdir -p "${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/.resume"

  local resume_script="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/.resume/resume-batch-${blocked_issue}.sh"

  cat > "$resume_script" <<EOF
#!/bin/bash
# Auto-generated batch resume script
# Blocked on issue: #${blocked_issue}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

echo "🔄 Resuming batch processing..."
echo "Remaining issues: ${resume_list[*]}"
echo ""

# Resume with remaining issues
rite ${resume_list[*]}
EOF

  chmod +x "$resume_script"

  print_success "Batch resume script created: $resume_script"
}
