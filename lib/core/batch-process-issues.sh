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

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_BATCH_PROCESS_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_BATCH_PROCESS_LOADED=true

# Generate a unique batch ID for this invocation so that parallel batches in
# the same project each get their own SESSION_STATE_FILE.
# Use epoch-seconds + PID + RANDOM for portability: date +%s works on both
# macOS (BSD) and Linux, and the PID+RANDOM suffix prevents collisions when
# two batches start within the same second.
if [ -z "${RITE_BATCH_ID:-}" ]; then
  RITE_BATCH_ID="$(date +%s)-$$-${RANDOM}"
  export RITE_BATCH_ID
fi

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Re-derive SESSION_STATE_FILE via config.sh now that RITE_BATCH_ID is set.
# When bin/rite invokes this script via exec, config.sh was already sourced by
# the parent (with no RITE_BATCH_ID set yet), so SESSION_STATE_FILE is stale.
# Re-sourcing config.sh with RITE_BATCH_ID exported lets its canonical path
# formula (_batch_id_suffix logic) produce the correct per-batch path,
# keeping path derivation in one place so any future rename stays in sync.
unset SESSION_STATE_FILE
source "$_SCRIPT_DIR/../utils/config.sh"

# Source libraries
source "$RITE_LIB_DIR/utils/session-tracker.sh"
source "$RITE_LIB_DIR/utils/notifications.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
source "$RITE_LIB_DIR/utils/logging.sh"

source "$RITE_LIB_DIR/utils/colors.sh"

# Summary computation + stats-output functions (sourceable by regression tests)
source "$_SCRIPT_DIR/batch-reporter.sh"

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
      FETCHED_ISSUES=$(gh_safe issue list --label "$FILTER_VALUE" --state open --json number --jq '.[].number' | sort -n | tr '\n' ' ' || true)
      ;;
    milestone)
      FETCHED_ISSUES=$(gh_safe issue list --milestone "$FILTER_VALUE" --state open --json number --jq '.[].number' | sort -n | tr '\n' ' ' || true)
      ;;
    state)
      FETCHED_ISSUES=$(gh_safe issue list --state "$FILTER_VALUE" --json number --jq '.[].number' | sort -n | tr '\n' ' ' || true)
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

# Register a cleanup trap so the per-batch state file is removed on any exit
# (normal, error, kill).  Without this, abnormal exits (break/exit 1/5/10 or
# SIGTERM) leave orphaned /tmp files that grow unbounded across batch runs.
# The trap fires after the summary report exits, so cleanup always runs.
#
# The trap also emits a RITE_EXIT diag so silent exits from the batch
# dispatcher itself (set -e firing in the loop, subshell crashes, etc.) are
# observable in the log. The per-issue workflow-runner.sh process has its
# own RITE_EXIT diag — this one covers the batch orchestrator. See issue #471.
_cleanup_batch_session() {
  local rc=$?
  if declare -f _diag >/dev/null 2>&1; then
    _diag "RITE_EXIT code=${rc} mode=batch current_issue=${ISSUE_NUM:-unknown}"
  fi
  rm -f "${SESSION_STATE_FILE:-}"
}
trap '_cleanup_batch_session' EXIT

# Initialize session tracking
init_session "batch-${ISSUE_LIST[0]}-$(date +%s)"

# Batch processing state
BATCH_START_TIME=$(date +%s)
TOTAL_ISSUES=${#ISSUE_LIST[@]}
COMPLETED_ISSUES=0
MERGED_CLEANUP_FAILED=()         # Exit 6: merged but cleanup crashed
FAILED_ISSUES=()                 # Exit 1: genuine failure (dev or merge)
BLOCKED_ISSUES=()                # Exit 2: blocker
SKIPPED_ISSUES=()                # Various skip reasons (all counted together for stats)
ALREADY_CLOSED_AT_START_ISSUES=() # Exit 12: already closed when batch started, no new work

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
#
# The regex requires the issue number to follow workflow-runner.sh or
# claude-workflow.sh as a positional argument — NOT just appear anywhere on
# the line. The old pattern (" ${N}( |$)") false-positived against:
#   - the PID column (ps -eo pid,command pads with spaces, so a workflow-runner.sh
#     whose PID is N produces a line containing " N " from the PID column itself)
#   - any unrelated number that happened to land between spaces in argv
# Live failure: 2026-06-08 batch for issues 393 395 377 silently skipped 377
# even though no process was running it.
#
# When the skip fires we also print the matched line so a future false positive
# is debuggable from the log instead of requiring live process inspection.
_all_procs=$(ps -eo command 2>/dev/null || true)
_active_matches=$(echo "$_all_procs" | grep -E "(workflow-runner|claude-workflow)\.sh" | grep -v "grep" || true)
_filtered_list=()
_active_skipped=()
declare -A _active_skipped_matches
for _issue_num in "${ISSUE_LIST[@]}"; do
  _match_line=$(echo "$_active_matches" | grep -E "(workflow-runner|claude-workflow)\.sh ${_issue_num}( |$)" | head -1 || true)
  if [ -n "$_match_line" ]; then
    _active_skipped+=("$_issue_num")
    _active_skipped_matches["$_issue_num"]="$_match_line"
  else
    _filtered_list+=("$_issue_num")
  fi
done
if [ ${#_active_skipped[@]} -gt 0 ]; then
  print_warning "Skipping issues already running: ${_active_skipped[*]}"
  for _skip_issue in "${_active_skipped[@]}"; do
    print_info "  #${_skip_issue} matched: ${_active_skipped_matches[$_skip_issue]}"
  done
  ISSUE_LIST=("${_filtered_list[@]}")
  TOTAL_ISSUES=${#ISSUE_LIST[@]}
fi

# Check session limits upfront
SESSION_STATE=$(get_session_info)
ISSUES_COMPLETED=$(echo "$SESSION_STATE" | jq -r '.issues_completed')
# Use cumulative active work (not wall-clock age of the state file) — issue #283.
# get_cumulative_work_seconds returns the sum of per-issue tracked durations, so a
# zombie file from a prior batch contributes 0 seconds of active work.
CUMULATIVE_SECS=$(get_cumulative_work_seconds)
ELAPSED_HOURS=$(( CUMULATIVE_SECS / 3600 ))

# Issue-count cap removed — was a stale heuristic with misleading "token limit"
# message. The real session-budget signal is the cumulative-hours cap enforced
# inside the batch loop below.

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
      PREFLIGHT_BLOCKER_MSGS+=("$BLOCKER_TYPE")
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

# Layer 3 — Session-level remote-ref prefetch (optional, best-effort):
# A single `git fetch --prune` refreshes refs/remotes/origin/* so per-issue
# closed-issue cleanup can use `git show-ref --verify --quiet refs/remotes/origin/<branch>`
# (local, instant) instead of a per-issue `git ls-remote` (network).
# This is a belt-and-suspenders optimization: Layer 1 already eliminates the
# network call for merged PRs (the common case). This helps the rare
# closed-not-merged path scale to large batches without compounding latency.
# Failure is non-fatal — per-issue cleanup degrades gracefully.
_BATCH_FETCH_PRUNE_DONE=false
print_info "Prefetching remote refs (git fetch --prune)..."
if timeout 10 git fetch --prune origin >/dev/null 2>&1; then
  _BATCH_FETCH_PRUNE_DONE=true
  print_success "Remote refs up to date"
else
  print_warning "git fetch --prune failed or timed out (non-fatal — cleanup will use network checks)"
fi
export _BATCH_FETCH_PRUNE_DONE
echo ""

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

  # Fetch issue details
  ISSUE_DETAILS=$(gh_safe issue view "$ISSUE_NUM" --json title,labels,state)
  ISSUE_DETAILS="${ISSUE_DETAILS:-"{}"}"

  if [ "$ISSUE_DETAILS" = "{}" ]; then
    print_error "Issue #$ISSUE_NUM not found"
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="not_found"
    continue
  fi

  ISSUE_TITLE=$(echo "$ISSUE_DETAILS" | jq -r '.title')
  ISSUE_STATE=$(echo "$ISSUE_DETAILS" | jq -r '.state')

  print_info "Title: $ISSUE_TITLE"
  print_info "State: $ISSUE_STATE"
  echo ""

  # Closed issues: do NOT short-circuit here. Let workflow-runner.sh handle them
  # via run_workflow() → handle_closed_issue(). That path prints the full closure
  # summary, removes dangling artifacts (worktree, local branch, remote branch,
  # session state file), and returns exit 0 — which the batch records as
  # "completed" and continues to the next issue.
  #
  # Parity contract: batch mode must produce identical per-issue side effects as
  # single-issue mode. Short-circuiting here would skip all cleanup that
  # workflow-runner.sh performs for closed issues.
  # See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity"
  # Bug history: #274 — batch silently bypassed closed-issue cleanup for 8 orphan
  # worktrees that accumulated from issues processed via batch (#34, #201-#203).

  # Check if this is a follow-up issue with parent PR dependency
  ISSUE_BODY=$(gh_safe issue view "$ISSUE_NUM" --json body --jq '.body')
  ISSUE_BODY="${ISSUE_BODY:-}"
  PARENT_PR=""

  # Require digits in the outer guard too — otherwise issue bodies that DOCUMENT
  # the marker format (e.g. "sharkrite-parent-pr:N" as an example) trigger the
  # inner extraction, which returns empty, which under set -e + pipefail kills
  # the script silently. Live bug: issue #34's body listed the marker as an
  # example and the entire batch died mid-stream with no error output.
  if echo "$ISSUE_BODY" | grep -qE "${RITE_MARKER_PARENT_PR}:[0-9]+"; then
    # Extract parent PR number from body marker
    PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE "${RITE_MARKER_PARENT_PR}:[0-9]+" | cut -d: -f2 || true)

    if [ -n "$PARENT_PR" ]; then
      # Check if parent PR is still open
      PARENT_PR_STATE=$(gh_safe pr view "$PARENT_PR" --json state --jq '.state')
      PARENT_PR_STATE="${PARENT_PR_STATE:-}"

      # Resolve parent issue number from parent PR body — needed by both the
      # OPEN branch (queue-membership check) and the MERGED branch (status
      # message). Must run unconditionally before the state dispatch; live
      # crash 2026-06-05 (finance-glance): PARENT_ISSUE was only set inside
      # the OPEN branch, so the MERGED branch hit `unbound variable`.
      PARENT_ISSUE=$(gh_safe pr view "$PARENT_PR" --json body --jq '.body' | grep -oE "$CLOSING_ISSUE_GREP_REGEX" | head -1 | grep -oE '[0-9]+' || true)
      PARENT_ISSUE="${PARENT_ISSUE:-}"

      if [ "$PARENT_PR_STATE" = "OPEN" ]; then
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
          print_info "Follow-up work will update parent issue #$PARENT_ISSUE's PR before merging parent"
        else
          # Deliberate divergence from single-issue mode: batch skips follow-up
          # issues whose parent PR is still open AND the parent issue is not in
          # this batch. This is an orchestrator-level decision that requires
          # knowledge of the full queue — run_workflow() cannot make this call
          # because it processes one issue at a time without queue visibility.
          # The skip is correct: processing a follow-up before the parent merges
          # causes failures (the follow-up's code changes reference code that
          # hasn't landed yet). Single-issue mode does not have this guard because
          # the user invoking `rite N` is presumed to know the ordering constraint.
          # Regression test: tests/regression/batch-single-issue-parity.bats
          #   @test "parent-PR-deferred divergence: documented and intentional"
          print_warning "⏸️  Parent issue #$PARENT_ISSUE is still open - deferring issue #$ISSUE_NUM"
          print_info "This follow-up issue will be processed after parent issue merges"
          SKIPPED_ISSUES+=("$ISSUE_NUM")
          ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"
          echo ""
          continue
        fi
      elif [ "$PARENT_PR_STATE" = "MERGED" ]; then
        print_success "✅ Parent issue #$PARENT_ISSUE is merged - proceeding with follow-up"
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
      if [ "$dep_status" = "failed" ] || [ "$dep_status" = "blocked" ] || [ "$dep_status" = "not_found" ] || [ "$dep_status" = "dep_failed" ]; then
        DEP_FAILED=true
        FAILED_DEP="$dep_num"
        DEP_REASON="$dep_status in this batch"
        break
      fi
      # Also check if dep issue is still open with an unmerged PR
      dep_issue_state=$(gh_safe issue view "$dep_num" --json state --jq '.state')
      dep_issue_state="${dep_issue_state:-}"
      if [ "$dep_issue_state" = "OPEN" ]; then
        DEP_FAILED=true
        FAILED_DEP="$dep_num"
        DEP_REASON="issue still open (PR not merged)"
        break
      fi
    done
    if [ "$DEP_FAILED" = true ]; then
      # Deliberate divergence from single-issue mode: batch skips dependent issues
      # when a dependency failed/was blocked/is still open within the same batch.
      # This is an orchestrator-level decision that requires the batch's accumulated
      # ISSUE_STATUS map — run_workflow() processes one issue at a time and cannot
      # know what happened to sibling issues in this run. Single-issue mode has no
      # equivalent guard: the user invoking `rite N` is presumed to have resolved
      # dependencies manually. Processing a dependent issue while its dependency
      # hasn't landed causes predictable failures (missing schema, missing APIs, etc.).
      # Regression test: tests/regression/batch-single-issue-parity.bats
      #   @test "dep-failed divergence: documented and intentional"
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
      # Deliberate divergence from single-issue mode: batch skips issues that
      # are actively running in a concurrent rite/claude process. This is a
      # safety guard to prevent two sessions from racing on the same issue and
      # corrupting the branch, worktree, or session state. Single-issue mode
      # does not have this guard because invoking `rite N` directly while another
      # `rite N` runs is intentional (e.g., supervised retry) and the user accepts
      # responsibility. In batch mode, the same issue appearing twice would be a
      # bug in the queue, not an intentional retry.
      # Regression test: tests/regression/batch-single-issue-parity.bats
      #   @test "active-process divergence: documented and intentional"
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
  for pr_num in $(gh_safe pr list --state open --json number --jq '.[].number' || true); do
    if gh_safe pr view "$pr_num" --json body --jq '.body' | grep -q "Closes #${ISSUE_NUM}\$\|Closes #${ISSUE_NUM}[^0-9]" 2>/dev/null; then
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
      REVIEW_TIME=$(gh_safe pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt')
      REVIEW_TIME="${REVIEW_TIME:-}"

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
          NEW_REVIEW_TIME=$(gh_safe pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt')
          NEW_REVIEW_TIME="${NEW_REVIEW_TIME:-}"

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
    PR_BRANCH=$(gh_safe pr view "$EXISTING_PR" --json headRefName --jq '.headRefName')
    PR_BRANCH="${PR_BRANCH:-}"

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$PR_BRANCH" ] && [ "$CURRENT_BRANCH" = "$PR_BRANCH" ]; then
      # Deliberate divergence from single-issue mode: batch skips an issue if the
      # current working directory is already on that issue's branch. This prevents
      # git operations (checkout, worktree add) from conflicting with the active
      # branch. Single-issue mode allows this because the user explicitly chose the
      # issue and can resolve the conflict interactively. In batch mode, reusing the
      # current branch would corrupt its state for the remaining batch issues.
      # Regression test: tests/regression/batch-single-issue-parity.bats
      #   @test "in-current-branch divergence: documented and intentional"
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

  # Record per-issue start time for cumulative active-work tracking (issue #283).
  # end_issue_tracking is called in the success and failure branches below so
  # cumulative_work_seconds is always updated regardless of outcome.
  start_issue_tracking "$ISSUE_NUM"

  # Run workflow and capture exit code explicitly before any if/then test.
  # `if cmd; then` discards non-zero codes — use the canonical set-e-safe
  # capture pattern so exit 12 (closed at start), 0 (active completion), and
  # other non-zero codes (failures) are all distinguishable.
  # See: docs/architecture/exit-codes.md
  _WF_EXIT=0
  "$RITE_LIB_DIR/core/workflow-runner.sh" "$ISSUE_NUM" --unsupervised || _WF_EXIT=$?

  if [ $_WF_EXIT -eq 0 ]; then
    # Active completion: issue was worked on in this session. Gather PR stats
    # for the batch summary (PR number, branch, file/line counts, tech-debt).
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    # Get PR number for this issue (search by body text, most recent first).
    # jq `// empty` converts null (returned when the array is empty) to no output,
    # so bash captures "" instead of the literal 4-char string "null".
    # The bash-level strip below is belt-and-suspenders for any future call path
    # that may not use `// empty` at the jq layer.
    PR_NUMBER=$(gh_safe pr list --search "fixes #${ISSUE_NUM} OR closes #${ISSUE_NUM} in:body" --state all --json number --jq 'sort_by(.number) | reverse | .[0].number // empty')
    PR_NUMBER="${PR_NUMBER:-}"
    [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""

    print_success "Issue #$ISSUE_NUM completed successfully"
    if [ -n "$PR_NUMBER" ]; then
      print_info "PR: #$PR_NUMBER"
      ISSUE_PR["$ISSUE_NUM"]="$PR_NUMBER"

      # Capture branch name and changes summary
      BRANCH_NAME=$(gh_safe pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
      BRANCH_NAME="${BRANCH_NAME:-}"
      if [ -n "$BRANCH_NAME" ]; then
        ISSUE_BRANCH["$ISSUE_NUM"]="$BRANCH_NAME"
      fi

      # Capture changes summary (files changed + lines)
      PR_STATS=$(gh_safe pr view "$PR_NUMBER" --json additions,deletions,changedFiles --jq '"\(.changedFiles) files, +\(.additions)/-\(.deletions) lines"')
      PR_STATS="${PR_STATS:-}"
      if [ -n "$PR_STATS" ]; then
        PR_CHANGES["$PR_NUMBER"]="$PR_STATS"
      fi

      # Check for security doc updates
      SECURITY_DOC_UPDATED=$(gh_safe pr view "$PR_NUMBER" --json files --jq '.files[].path' | grep -c "docs/security/DEVELOPMENT-GUIDE.md" || true)
      if [ "$SECURITY_DOC_UPDATED" -gt 0 ]; then
        SECURITY_UPDATES+=("PR #$PR_NUMBER: Updated DEVELOPMENT-GUIDE.md with findings from #$ISSUE_NUM")
      fi

      # Check for new tech-debt issues created.
      # `// empty` prevents jq from outputting literal "null" when no issue matches.
      NEW_DEBT_ISSUE=$(gh_safe issue list --label "tech-debt" --state open --search "${RITE_MARKER_PARENT_PR}:$PR_NUMBER in:body" --json number --jq '.[0].number // empty')
      NEW_DEBT_ISSUE="${NEW_DEBT_ISSUE:-}"
      [ "$NEW_DEBT_ISSUE" = "null" ] && NEW_DEBT_ISSUE=""
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

  elif [ $_WF_EXIT -eq 12 ]; then
    # Already closed at start: handle_closed_issue() ran and printed the closure
    # summary + cleaned any orphan artifacts. No dev session ran — skip all the
    # post-issue gh API calls (pr list, pr view x3, issue list) that gather stats
    # for the batch report. Those calls are only meaningful after active dev work.
    #
    # Parity note: the per-issue SIDE EFFECTS (closure summary, artifact cleanup)
    # are identical to single-issue mode — that's the parity contract. The batch-
    # level REPORTING layer is intentionally differentiated based on what kind of
    # work happened. This is documented divergence, not a parity violation.
    # See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity"
    # See: docs/architecture/exit-codes.md — exit code 12
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_info "Issue #$ISSUE_NUM was already closed — no new work this session"
    print_info "Duration: ${ISSUE_DURATION}s"
    echo ""

    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ALREADY_CLOSED_AT_START_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="already_closed_at_start"

  else
    EXIT_CODE=$_WF_EXIT
    # Record end of per-issue tracking regardless of failure type (issue #283)
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    # Classify failure type based on exit code
    if [ $EXIT_CODE -eq 6 ]; then
      # Merge succeeded but cleanup failed — work IS on remote
      print_warning "Issue #$ISSUE_NUM: merge succeeded but cleanup failed (exit code: 6)"
      print_info "Duration: ${ISSUE_DURATION}s"
      echo ""
      MERGED_CLEANUP_FAILED+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="merged_cleanup_failed"

      # Get PR number so we can show the URL in the summary
      PR_NUMBER=$(gh_safe pr list --search "fixes #${ISSUE_NUM} OR closes #${ISSUE_NUM} in:body" --state all --json number --jq 'sort_by(.number) | reverse | .[0].number')
      PR_NUMBER="${PR_NUMBER:-}"
      if [ -n "$PR_NUMBER" ]; then
        ISSUE_PR["$ISSUE_NUM"]="$PR_NUMBER"
      fi

    elif [ $EXIT_CODE -eq 13 ]; then
      # Invariant violated: workflow completed all phases but produced no commits
      # and no PR — this is a bug in the workflow logic or a sourcing side-effect.
      # The full diagnostic was already printed by run_workflow before it returned 13.
      # Record as a distinct failure class (not the same as a dev/merge failure)
      # so operators can identify phantom completions in the batch log.
      # Continue the loop — other issues are not affected by this bug.
      # See: docs/architecture/exit-codes.md (exit 13 — invariant violated)
      print_error "Issue #$ISSUE_NUM: workflow invariant violated — no commits and no PR produced (exit code: 13)"
      print_error "This is a workflow logic bug, not a user-actionable failure — check logs above"
      print_info "Duration: ${ISSUE_DURATION}s"
      echo ""
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="invariant_violated"

    elif [ $EXIT_CODE -eq 5 ]; then
      # Usage cap reached — abort the entire batch to avoid hammering the API
      print_error "Issue #$ISSUE_NUM hit usage cap (exit code: 5) — aborting batch"
      print_info "Duration: ${ISSUE_DURATION}s"
      echo ""
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="usage_cap"
      break

    elif [ $EXIT_CODE -eq 10 ]; then
      # Blocker detected - defer instead of stopping
      print_error "Issue #$ISSUE_NUM failed (exit code: $EXIT_CODE)"
      print_info "Duration: ${ISSUE_DURATION}s"
      echo ""
      print_warning "⏸️  Blocker detected - deferring issue #$ISSUE_NUM"
      BLOCKED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="blocked"

      # Send blocker notification
      send_blocker_notification "Workflow Blocker" "$ISSUE_NUM"

      print_info "Will retry after processing remaining issues"
      echo ""
      # Continue with next issue instead of breaking

    else
      # Other failure (dev or merge actually failed)
      print_error "Issue #$ISSUE_NUM failed (exit code: $EXIT_CODE)"
      print_info "Duration: ${ISSUE_DURATION}s"
      echo ""
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="failed"
    fi
  fi

  # Issue-count cap removed. Only cumulative active-work hours cap matters now.
  CUMULATIVE_SECS=$(get_cumulative_work_seconds)
  ELAPSED_HOURS=$(( CUMULATIVE_SECS / 3600 ))
  if [ "$ELAPSED_HOURS" -ge "${RITE_MAX_SESSION_HOURS:-12}" ]; then
    print_warning "Cumulative active-work limit reached (${ELAPSED_HOURS}h)"
    print_info "Stopping batch processing"
    break
  fi

  # No between-issue delay: gh_safe handles 429/5xx with exponential backoff
  # and Claude provider calls have their own retry logic. The original 5s sleep
  # was defensive against rate limits before gh_safe existed; it's pure overhead
  # now. For an 8-issue batch the wait alone added 35s — often >90% of total
  # batch time after #316's closed-issue optimization.
  if [ "$CURRENT_ISSUE" -lt "$TOTAL_ISSUES" ]; then
    echo ""
  fi
done

# Calculate final stats
# TOTAL_PROCESSED = issues that actually ran through the workflow (completed, failed, or blocked).
# Skipped issues (waiting_for_parent, already_closed, dep_failed, etc.) are intentionally
# excluded — they never entered the workflow — and are reported separately via ${#SKIPPED_ISSUES[@]}.
BATCH_END_TIME=$(date +%s)
TOTAL_DURATION=$((BATCH_END_TIME - BATCH_START_TIME))
_batch_compute_totals

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
    FOLLOWUP_ISSUE=$(gh_safe issue list --search "parent-pr in:body in:title" --label "review-follow-up" --state open --json number,body --jq ".[] | select(.body | contains(\"#$ISSUE_NUM\")) | .number" | head -1 || true)
    FOLLOWUP_ISSUE="${FOLLOWUP_ISSUE:-}"

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

# Emit Overall Statistics + Skipped Issues sections via the extracted function.
# The function is the single source of truth for this output — regression tests
# source this file and call it directly so they bind to the real formula.
_batch_print_stats

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

if [ ${#MERGED_CLEANUP_FAILED[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Merged (with cleanup warnings)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${MERGED_CLEANUP_FAILED[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
    REPO_URL=$(gh_safe repo view --json url --jq '.url' || true)
    REPO_URL="${REPO_URL:-}"
    if [ -n "$REPO_URL" ] && [ "$PR_NUM" != "N/A" ]; then
      echo "  ⚠️  Issue #$ISSUE_NUM → PR #$PR_NUM (${DURATION}s) - ${REPO_URL}/pull/${PR_NUM}"
    else
      echo "  ⚠️  Issue #$ISSUE_NUM → PR #$PR_NUM (${DURATION}s)"
    fi
  done | sort -t'#' -k2 -n
  echo ""
  print_info "These PRs merged successfully but post-merge cleanup encountered errors"
  print_info "Work IS on remote — no need to re-run"
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

# (Skipped Issues section is now emitted by _batch_print_stats above)

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
TOTAL_TOKENS=$(echo "$SESSION_STATE" | jq -r '.tokens_used // 0' || true)
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
