#!/bin/bash
# workflow-runner.sh
# Central orchestrator for automated GitHub workflow with safety mechanisms
# Usage: ./workflow-runner.sh ISSUE_NUMBER [--supervised|--unsupervised] [--resume]

set -euo pipefail

# ===================================================================
# CONFIGURATION
# ===================================================================

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../utils/config.sh"
fi

# Source all library modules
source "$RITE_LIB_DIR/utils/notifications.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"
source "$RITE_LIB_DIR/utils/session-tracker.sh"

# Workflow mode: supervised (requires confirmations) or unsupervised (fully automated)
WORKFLOW_MODE="${WORKFLOW_MODE:-supervised}"
RESUME_MODE=false
BYPASS_BLOCKERS=false

# Script paths (all in core/)
CLAUDE_WORKFLOW="$RITE_LIB_DIR/core/claude-workflow.sh"
CREATE_PR="$RITE_LIB_DIR/core/create-pr.sh"
ASSESS_RESOLVE="$RITE_LIB_DIR/core/assess-and-resolve.sh"
MERGE_PR="$RITE_LIB_DIR/core/merge-pr.sh"

# ===================================================================
# UTILITY FUNCTIONS
# ===================================================================

print_header() {
  echo ""
  echo "==========================================="
  echo "$1"
  echo "==========================================="
  echo ""
}

print_info() {
  echo "ℹ️  $1"
}

print_success() {
  echo "✅ $1"
}

print_error() {
  echo "❌ ERROR: $1" >&2
}

print_warning() {
  echo "⚠️  WARNING: $1"
}

# ===================================================================
# BLOCKER HANDLING
# ===================================================================

handle_blocker() {
  local context="$1"
  local issue_number="$2"
  local pr_number="${3:-}"

  local blocker_type="${BLOCKER_TYPE:-unknown}"
  local blocker_details="${BLOCKER_DETAILS:-No details available}"
  local worktree_path="${WORKTREE_PATH:-}"

  print_header "🚨 BLOCKER DETECTED: $blocker_type"

  echo "$blocker_details"
  echo ""

  # Get urgency level
  local urgency=$(get_blocker_urgency "$blocker_type")
  local blocks_batch=$(is_blocking_batch "$blocker_type")
  local is_batch_mode="${BATCH_MODE:-false}"

  # Save session state (no resume script)
  save_session_state "$issue_number" "$blocker_type" "$worktree_path"

  # Send notifications ONLY for mid-workflow failures (not pre-start)
  if [ "$context" != "pre-start" ]; then
    send_blocker_notification "$blocker_type" "$issue_number" "$pr_number" "$worktree_path" "$blocker_details"
  else
    echo "ℹ️  Note: Initial check failed - no notification sent"
  fi

  # Show context-aware next steps
  echo ""
  echo "📋 Next Steps:"

  case "$blocker_type" in
    credentials_expired)
      echo "1. Refresh AWS credentials:"
      echo ""
      echo "   aws sso login --profile ${RITE_AWS_PROFILE:-default}"
      echo ""
      echo "2. Resume workflow:"
      echo ""
      echo "   forge ${issue_number}"
      ;;

    auth_changes|architectural_docs|protected_scripts)
      echo "1. Review the changes shown above"
      echo "2. To bypass this blocker:"
      echo ""
      echo "   # Supervised mode (bypasses blockers with terminal approval):"
      echo "   forge ${issue_number} --supervised"
      echo ""
      echo "   # Or unsupervised bypass (warnings sent to Slack):"
      echo "   forge ${issue_number} --bypass-blockers"
      ;;

    infrastructure|database_migration)
      echo "1. Review the changes shown above"
      echo "2. Test locally if needed"
      echo "3. Confirm it's safe to proceed"
      echo "4. Resume workflow:"
      echo ""
      echo "   forge ${issue_number}"
      ;;

    test_failures|build_failures)
      echo "1. Review test/build failures above"
      echo "2. Fix issues locally or in the PR"
      echo "3. Push fixes to the branch"
      echo "4. Resume workflow:"
      echo ""
      echo "   forge ${issue_number}"
      ;;

    critical_issues)
      echo "1. Review security issues in PR"
      echo "2. Fix critical issues on the branch"
      echo "3. Push fixes and wait for new review"
      echo "4. Resume workflow:"
      echo ""
      echo "   forge ${issue_number}"
      ;;

    session_limit|token_limit)
      echo "1. Take a break (session limits reached)"
      echo "2. Resume in fresh session when ready:"
      echo ""
      echo "   forge ${issue_number}"
      ;;

    *)
      echo "1. Review blocker details above"
      echo "2. Take necessary action"
      echo "3. Resume workflow when ready:"
      echo ""
      echo "   forge ${issue_number}"
      ;;
  esac

  echo ""

  # Supervised mode: user is watching — prompt before bypassing
  if [ "$WORKFLOW_MODE" = "supervised" ]; then
    print_warning "⚠️  BLOCKER: $blocker_type"
    echo ""
    read -p "Review the above. Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      print_warning "Blocker acknowledged — continuing workflow"
      return 0
    else
      print_info "Workflow paused. Run 'forge ${issue_number}' to resume later."
      exit 1
    fi
  fi

  # Unsupervised + --bypass-blockers: bypass all blockers, warnings sent to Slack
  if [ "$BYPASS_BLOCKERS" = true ]; then
    print_warning "Blocker bypassed (--bypass-blockers): $blocker_type"
    print_info "Warning sent to Slack — continuing workflow"
    return 0
  fi

  # Unsupervised without bypass: stop on blockers
  if [ "$is_batch_mode" = "true" ] && [ "$blocks_batch" = "true" ]; then
    print_warning "Blocker affects entire batch - stopping batch processing"
    exit 1
  elif [ "$is_batch_mode" = "true" ]; then
    print_warning "Blocker only affects this issue - continuing with next issue"
    increment_failed
    return 1
  else
    # Single issue unsupervised mode - stop
    exit 1
  fi
}

# ===================================================================
# WORKFLOW PHASES
# ===================================================================

phase_pre_start_checks() {
  local issue_number="$1"

  # Check credentials (blocker handler will print header if needed)
  if ! check_blockers "pre-start"; then
    handle_blocker "pre-start" "$issue_number"
    return 1
  fi

  # Check session limits
  local issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local elapsed_hours=$(get_elapsed_hours)

  if ! check_blockers "session-check" "$issues_completed" "$elapsed_hours"; then
    handle_blocker "session-check" "$issue_number"
    return 1
  fi

  print_success "Pre-start checks passed"
  return 0
}

phase_claude_workflow() {
  local issue_number="$1"

  print_header "Phase 1: Claude Workflow (Development)"

  set_current_issue "$issue_number"

  # Check if resuming or starting fresh
  if [ "$RESUME_MODE" = true ]; then
    print_info "Resuming work on issue #${issue_number}"

    # Worktree should already exist
    if [ -z "$WORKTREE_PATH" ]; then
      print_error "Resume mode but no worktree path set"
      return 1
    fi

    cd "$WORKTREE_PATH"
    print_info "Using existing worktree: $WORKTREE_PATH"
  else
    # Check if PR already exists for this issue
    pr_number=$(gh pr list --state open --json number,body --limit 100 2>/dev/null | \
      jq --arg issue "$issue_number" -r '.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .number' | \
      head -1)

    if [ -n "$pr_number" ]; then
      print_info "Found existing PR #$pr_number for issue #$issue_number"

      # Find worktree for this PR's branch
      pr_branch=$(gh pr view "$pr_number" --json headRefName --jq '.headRefName')
      worktree_path=$(git worktree list | grep "\[$pr_branch\]" | awk '{print $1}')

      if [ -n "$worktree_path" ]; then
        WORKTREE_PATH="$worktree_path"
        set_current_worktree "$WORKTREE_PATH"
        print_success "Using existing worktree: $WORKTREE_PATH"

        # Check for uncommitted changes in the target worktree (exclude symlinks and untracked)
        TARGET_UNCOMMITTED=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | grep -vE "^\?\?" | wc -l | tr -d ' ')
        if [ "$TARGET_UNCOMMITTED" -gt 0 ]; then
          print_warning "Uncommitted changes detected in worktree"

          # Get issue description for relevance analysis
          issue_desc=$(gh issue view "$issue_number" --json title,body --jq '.title + "\n\n" + .body' 2>/dev/null || echo "")

          # Get diff of uncommitted changes (exclude untracked files)
          UNCOMMITTED_DIFF=$(git -C "$WORKTREE_PATH" diff HEAD 2>/dev/null || echo "")
          UNCOMMITTED_FILES=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | grep -vE "^\?\?" || echo "")

          if [ -z "$UNCOMMITTED_FILES" ]; then
            print_info "No tracked file changes (only untracked files)"
          else
            # Use Claude CLI to analyze if changes are relevant to the issue
            print_info "Analyzing if changes are relevant to issue #$issue_number..."

            # Create temp file for prompt to avoid heredoc issues
            PROMPT_FILE=$(mktemp)
            cat > "$PROMPT_FILE" <<EOF
You are analyzing uncommitted code changes to determine if they are relevant to a GitHub issue.

**Issue #$issue_number:**
$issue_desc

**Uncommitted changes:**
$UNCOMMITTED_FILES

**Diff:**
$UNCOMMITTED_DIFF

**Task:** Determine if these changes are implementing/fixing the issue described above.

Answer with ONLY ONE WORD:
- RELEVANT: if changes implement or relate to the issue
- UNRELATED: if changes are unrelated to the issue

Answer:
EOF

            RELEVANCE=$(claude < "$PROMPT_FILE" 2>/dev/null | grep -oiE "(RELEVANT|UNRELATED)" | head -1 | tr '[:lower:]' '[:upper:]')
            rm -f "$PROMPT_FILE"

            # If Claude CLI failed or returned nothing, fail hard
            if [ -z "$RELEVANCE" ]; then
              print_error "Claude CLI failed to analyze changes"
              print_error "Cannot proceed without determining relevance"
              echo ""
              echo "Uncommitted changes:"
              echo "$UNCOMMITTED_FILES"
              echo ""
              echo "Please manually commit or stash changes in: $WORKTREE_PATH"
              exit 1
            fi

            print_info "Assessment: $RELEVANCE"

            if [ "$RELEVANCE" = "RELEVANT" ]; then
              # Changes are relevant - commit them
              print_success "Changes are relevant to issue #$issue_number - committing..."

              cd "$WORKTREE_PATH" || exit 1
              git add -u  # Only add tracked files (not symlinks)
              COMMIT_MSG="wip: auto-commit relevant changes for issue #$issue_number ($(date +%Y-%m-%d))"

              if git commit -m "$COMMIT_MSG" 2>/dev/null; then
                print_success "Changes committed: $COMMIT_MSG"
              else
                print_error "Failed to commit changes"
                exit 1
              fi
            else
              # Changes are unrelated - stash them, will be popped after workflow completes
              print_info "Changes are unrelated to issue #$issue_number - stashing..."

              cd "$WORKTREE_PATH" || exit 1
              STASH_MSG="Auto-stash unrelated work before issue #$issue_number ($(date +%Y-%m-%d))"

              if git stash push -u -m "$STASH_MSG" 2>/dev/null; then
                print_success "Changes stashed: $STASH_MSG"
                print_info "Will be restored after workflow completes"

                # Set flag to pop stash at end of workflow
                export STASHED_UNRELATED_WORK=true
                export STASH_MESSAGE="$STASH_MSG"
              else
                print_error "Failed to stash changes"
                exit 1
              fi
            fi
          fi
        fi

        print_info "Skipping Phase 1 - PR already exists, proceeding to Phase 2"
        # CRITICAL: Return here to skip worktree creation logic below
        # The worktree already exists and WORKTREE_PATH is set
        print_success "Development phase complete"
        return 0
      else
        print_error "PR exists but worktree not found - manual intervention required"
        print_error "Run: git worktree add $RITE_WORKTREE_DIR/$pr_branch $pr_branch"
        return 1
      fi
    else
      print_info "Starting fresh on issue #${issue_number}"

      # Call claude-workflow.sh to create worktree and do development
      # claude-workflow.sh handles detecting uncommitted changes internally
      # (its SKIP_CLAUDE flag triggers when changes exist in the worktree)
      if [ "$WORKFLOW_MODE" = "supervised" ]; then
        "$CLAUDE_WORKFLOW" "$issue_number"
      else
        # Unsupervised: pass --auto flag
        "$CLAUDE_WORKFLOW" "$issue_number" --auto
      fi

      # Extract worktree path - look for any non-main worktree created for this issue
      # Try multiple patterns: issue number in path, or get the most recently created worktree
      MAIN_WORKTREE=$(git rev-parse --show-toplevel)
      WORKTREE_PATH=$(git worktree list | awk '{print $1}' | grep -v "^${MAIN_WORKTREE}$" | grep -E "(issue.?${issue_number}|#${issue_number})" | head -1)

      # If not found by issue number, get the most recently modified worktree
      if [ -z "$WORKTREE_PATH" ]; then
        WORKTREE_PATH=$(git worktree list | awk '{print $1}' | grep -v "^${MAIN_WORKTREE}$" | xargs -I {} stat -f "%m %N" {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
      fi

      if [ -z "$WORKTREE_PATH" ]; then
        print_error "Worktree not found after claude-workflow.sh"
        print_info "Available worktrees:"
        git worktree list
        return 1
      fi

      set_current_worktree "$WORKTREE_PATH"
    fi
  fi

  print_success "Development phase complete"
  return 0
}

phase_create_pr() {
  local issue_number="$1"

  print_header "Phase 2: Push Work and Wait for Review"

  cd "$WORKTREE_PATH"

  # Extract PR number from git branch metadata or gh pr view
  local branch_name=$(git rev-parse --abbrev-ref HEAD)
  PR_NUMBER=$(gh pr view "$branch_name" --json number --jq '.number' 2>/dev/null || echo "")

  if [ -z "$PR_NUMBER" ]; then
    print_error "PR not created or not found"
    return 1
  fi

  # Call create-pr.sh (pushes commits if needed, waits for review to appear)
  # Does NOT run assessment - that happens in Phase 3
  # create-pr.sh may exit with code 10 if early blocker detection triggers
  set +e  # Temporarily disable exit-on-error to capture exit code
  if [ "$WORKFLOW_MODE" = "supervised" ]; then
    "$CREATE_PR"
  else
    "$CREATE_PR" --auto
  fi
  local create_pr_exit=$?
  set -e  # Re-enable exit-on-error

  # Handle exit codes from create-pr.sh
  if [ $create_pr_exit -eq 10 ]; then
    # Blocker detected in early detection (BLOCKER_TYPE and BLOCKER_DETAILS already exported)
    print_warning "Early blocker detected in PR phase"
    return 1
  elif [ $create_pr_exit -ne 0 ]; then
    print_error "create-pr.sh failed with exit code: $create_pr_exit"
    return 1
  fi

  return 0
}

phase_assess_and_resolve() {
  local issue_number="$1"
  local pr_number="$2"
  local retry_count="${3:-0}"  # Default to 0 if not provided
  local max_retries=3

  print_header "Phase 3: Assess Review and Resolve Issues"

  if [ $retry_count -gt 0 ]; then
    print_info "Retry attempt $retry_count of $max_retries"
  fi

  # Data flow: assess-and-resolve.sh outputs filtered review to stdout (no temp files)
  # We capture stdout and pipe directly to claude-workflow.sh for fixes

  cd "$WORKTREE_PATH"

  # Check for blockers before merge
  # Pass WORKFLOW_MODE so protected script blocker can allow supervised mode
  if ! check_blockers "pre-merge" "$pr_number" "$issue_number" "$WORKFLOW_MODE"; then
    handle_blocker "pre-merge" "$issue_number" "$pr_number"
    return 1
  fi

  # Call assess-and-resolve.sh (pass issue number and retry count)
  # This will categorize ALL review issues and either:
  # - If actionable_count == 0: exit 0 (merge)
  # - If actionable_count > 0 AND retry < 3: exit 2 (loop to fix)
  # - If retry >= 3 AND CRITICAL+ACTIONABLE: create follow-up, exit 1 (block merge)
  # - If retry >= 3 AND no CRITICAL: create security-debt, exit 0 (allow merge)
  # In AUTO_MODE with CRITICAL issues, it will output filtered review content to stdout
  # and exit with code 2 (no temp files needed - we capture stdout directly)

  # Run assessment and capture stdout (for exit code 2), let stderr display directly
  local review_content=""
  local assess_stdout=$(mktemp)

  # Run assessment - stderr goes directly to terminal, stdout captured for fixes
  echo "[WORKFLOW-RUNNER] About to call assess-and-resolve.sh..." >&2
  echo "[WORKFLOW-RUNNER] PR: $pr_number, Issue: $issue_number, Retry: $retry_count" >&2

  set +e  # Temporarily disable exit-on-error to capture exit code properly
  if [ "$WORKFLOW_MODE" = "supervised" ]; then
    "$ASSESS_RESOLVE" "$pr_number" "$issue_number" "$retry_count" > "$assess_stdout"
  else
    "$ASSESS_RESOLVE" "$pr_number" "$issue_number" "$retry_count" --auto > "$assess_stdout"
  fi
  local assessment_result=$?
  set -e  # Re-enable exit-on-error

  echo "[WORKFLOW-RUNNER] Assessment returned exit code: $assessment_result" >&2

  # Read stdout into variable (used for exit code 2 - fixes needed)
  review_content=$(cat "$assess_stdout")

  # Extract decision counts from stdout (when exit code 2)
  local now_count=0
  local later_count=0
  local dismissed_count=0

  if [ -n "$review_content" ]; then
    now_count=$(echo "$review_content" | grep -c "ACTIONABLE_NOW" 2>/dev/null | tr -d '[:space:]' || echo "0")
    later_count=$(echo "$review_content" | grep -c "ACTIONABLE_LATER" 2>/dev/null | tr -d '[:space:]' || echo "0")
    dismissed_count=$(echo "$review_content" | grep -c "DISMISSED" 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Validate they're integers
    [[ ! "$now_count" =~ ^[0-9]+$ ]] && now_count=0
    [[ ! "$later_count" =~ ^[0-9]+$ ]] && later_count=0
    [[ ! "$dismissed_count" =~ ^[0-9]+$ ]] && dismissed_count=0
  fi

  # Cleanup temp file
  rm -f "$assess_stdout"

  if [ $assessment_result -eq 2 ]; then
    # Critical issues found - need to fix and restart PR cycle
    print_warning "Critical issues found - invoking Claude to fix"

    if [ $now_count -gt 0 ] || [ $later_count -gt 0 ] || [ $dismissed_count -gt 0 ]; then
      print_info "Decision breakdown:"
      print_info "  • ACTIONABLE_NOW: $now_count items (fixing in this PR)"
      [ $later_count -gt 0 ] && print_info "  • ACTIONABLE_LATER: $later_count items (deferred)"
      [ $dismissed_count -gt 0 ] && print_info "  • DISMISSED: $dismissed_count items (ignored)"
    fi

    # Check if we've hit max retries
    if [ $retry_count -ge $max_retries ]; then
      print_error "Maximum retry attempts ($max_retries) reached - manual intervention required"
      print_warning "Creating follow-up issue for manual resolution"

      # Call assess-and-resolve in supervised mode to create follow-up issue
      print_info "Creating follow-up issue with remaining CRITICAL items"
      "$ASSESS_RESOLVE" "$pr_number" "$issue_number"

      return 1
    fi

    # Call claude-workflow.sh in fix mode to address the review issues
    # Pipe review content from assess-and-resolve directly to claude-workflow (no temp files!)
    cd "$WORKTREE_PATH" || return 1

    if [ -n "$review_content" ]; then
      print_info "Piping filtered review content to Claude workflow (no temp files)"
      echo "$review_content" | "$CLAUDE_WORKFLOW" "$issue_number" --fix-review --auto
    else
      print_error "No review content captured from assess-and-resolve"
      return 1
    fi

    # After fixes, restart from Phase 2 (create/update PR)
    phase_create_pr "$issue_number"

    # Increment retry count and recurse
    local next_retry=$((retry_count + 1))
    phase_assess_and_resolve "$issue_number" "$PR_NUMBER" "$next_retry"
    return $?
  elif [ $assessment_result -ne 0 ]; then
    print_error "Assessment failed"
    return 1
  fi

  # Assessment complete - decision already shown in Phase 3 header
  # (No redundant summary needed - assess-and-resolve.sh already printed decision box)

  if [ "$WORKFLOW_MODE" = "unsupervised" ]; then
    print_info "Auto mode: proceeding to merge workflow"
  fi

  return 0
}

phase_merge_pr() {
  local issue_number="$1"
  local pr_number="$2"

  print_header "Phase 4: Merge PR and Update Docs"

  cd "$WORKTREE_PATH"

  # merge-pr.sh will:
  # - Update security guide with findings from PR review
  # - Create follow-up issues if needed
  # - Merge PR
  # - Clean up worktree
  # - Send notifications
  if [ "$WORKFLOW_MODE" = "supervised" ]; then
    "$MERGE_PR" "$pr_number"
  else
    "$MERGE_PR" "$pr_number" --auto
  fi

  local merge_result=$?

  if [ $merge_result -ne 0 ]; then
    print_error "Merge failed"
    return 1
  fi

  print_success "PR #${pr_number} merged successfully"
  increment_completed

  # Restore stashed unrelated work if any (after merge completes)
  if [ "${STASHED_UNRELATED_WORK:-false}" = "true" ]; then
    echo ""
    print_header "🔄 Restoring Unrelated Work"

    cd "$WORKTREE_PATH" 2>/dev/null || cd "$(git rev-parse --show-toplevel)" || true

    # Find the stash by message
    STASH_INDEX=$(git stash list | grep -F "$STASH_MESSAGE" | head -1 | cut -d':' -f1 || echo "")

    if [ -n "$STASH_INDEX" ]; then
      print_info "Restoring stashed changes: $STASH_MESSAGE"

      if git stash pop "$STASH_INDEX" 2>/dev/null; then
        print_success "Unrelated work restored to worktree"
      else
        print_warning "Could not automatically restore stash (may have conflicts)"
        print_info "Manually restore with: git stash pop $STASH_INDEX"
      fi
    else
      print_warning "Stash not found - may have been already popped"
    fi
  fi

  return 0
}

phase_completion() {
  local issue_number="$1"
  local pr_number="$2"

  print_header "Phase 5: Completion"

  # Get PR details for notification
  local pr_title=$(gh pr view "$pr_number" --json title --jq '.title' 2>/dev/null || echo "Unknown")
  local files_changed=$(gh pr view "$pr_number" --json files --jq '.files | length' 2>/dev/null || echo "?")

  # Check if follow-up issues were created
  local followup_issues=$(gh issue list --label "follow-up" --label "parent:#${issue_number}" --json number --jq '. | length' 2>/dev/null || echo "0")

  # Send completion notification
  send_completion_notification "$issue_number" "$pr_number" "$pr_title" "$files_changed" "$followup_issues"

  # Show session summary
  echo ""
  get_session_summary
  echo ""

  # Clean up session state file now that workflow is complete
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    print_info "Cleaned up session state for issue #${issue_number}"
  fi

  print_success "Issue #${issue_number} workflow complete!"
  return 0
}

# ===================================================================
# MAIN WORKFLOW ORCHESTRATION
# ===================================================================

run_workflow() {
  local issue_number="$1"

  print_header "🤖 Automated Workflow Runner 🤖"

  echo "🚀 Processing issue #${issue_number} (full lifecycle)"
  echo "✅ Session initialized (mode: $WORKFLOW_MODE)"
  echo ""

  # Check if issue is already closed
  local issue_data=$(gh issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences 2>/dev/null)
  local issue_state=$(echo "$issue_data" | jq -r '.state')

  if [ "$issue_state" = "CLOSED" ]; then
    local issue_title=$(echo "$issue_data" | jq -r '.title')
    local closed_at=$(echo "$issue_data" | jq -r '.closedAt')

    # Find the PR that closed this issue
    local pr_number=$(echo "$issue_data" | jq -r '.closedByPullRequestsReferences[0].number // empty' | head -1)
    local pr_state=""
    local pr_merged=""
    local pr_summary=""

    if [ -n "$pr_number" ]; then
      local pr_data=$(gh pr view "$pr_number" --json state,mergedAt,body,headRefName 2>/dev/null)
      pr_state=$(echo "$pr_data" | jq -r '.state')
      pr_merged=$(echo "$pr_data" | jq -r '.mergedAt')
      pr_summary=$(echo "$pr_data" | jq -r '.body' | head -5)
      local pr_branch=$(echo "$pr_data" | jq -r '.headRefName')
    fi

    # Calculate time since closed (portable date parsing)
    local closed_timestamp
    if date --version >/dev/null 2>&1; then
      # GNU date
      closed_timestamp=$(date -d "$closed_at" "+%s" 2>/dev/null || echo "0")
    else
      # BSD date (macOS)
      closed_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$closed_at" "+%s" 2>/dev/null || echo "0")
    fi

    local current_timestamp=$(date +%s)
    local time_diff=$((current_timestamp - closed_timestamp))
    local time_ago=""

    if [ $time_diff -lt 0 ] || [ $closed_timestamp -eq 0 ]; then
      time_ago="recently"
    elif [ $time_diff -lt 3600 ]; then
      local minutes=$((time_diff / 60))
      time_ago="${minutes} minutes ago"
    elif [ $time_diff -lt 86400 ]; then
      local hours=$((time_diff / 3600))
      time_ago="${hours} hours ago"
    else
      local days=$((time_diff / 86400))
      time_ago="${days} days ago"
    fi

    echo ""
    echo "✅ Issue #${issue_number} is already closed!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Issue Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Title: $issue_title"
    echo "Closed: ${closed_at:0:10} ($time_ago)"

    if [ -n "$pr_number" ]; then
      echo "PR: #${pr_number} (${pr_state})"
      if [ "$pr_state" = "MERGED" ]; then
        echo "Merged: ${pr_merged:0:10}"
      fi
      if [ -n "$pr_branch" ]; then
        # Check if branch still exists
        if git show-ref --verify --quiet "refs/heads/$pr_branch" 2>/dev/null; then
          echo "Branch: $pr_branch (still exists)"
        else
          echo "Branch: $pr_branch (deleted after merge)"
        fi
      fi

      # Generate qualitative summary using Claude CLI
      echo ""
      echo "What was accomplished:"

      if command -v claude &> /dev/null; then
        # Get PR diff for context
        local pr_diff=$(gh pr diff "$pr_number" 2>/dev/null | head -100)

        # Use Claude to generate concise summary
        local summary_prompt=$(cat <<EOF
Analyze this pull request and provide a single sentence (max 20 words) describing what was accomplished.

Title: $issue_title
Files changed: $(gh pr view "$pr_number" --json files --jq '.files | length' 2>/dev/null) files

Focus on the user-facing impact or technical improvement, not implementation details.
Be specific and concise. Examples:
- "Added inline documentation explaining test coverage exclusion patterns"
- "Fixed authentication bug causing intermittent login failures"
- "Refactored database queries to improve performance by 40%"

Your turn - one sentence only:
EOF
)

        local claude_summary=$(echo "$summary_prompt" | claude --no-cache 2>/dev/null | head -1)

        if [ -n "$claude_summary" ]; then
          echo "  $claude_summary"
        else
          # Fallback to title
          echo "  $issue_title"
        fi
      else
        # Fallback to title if Claude unavailable
        echo "  $issue_title"
      fi

      # Show file changes
      echo ""
      echo "Files changed:"
      local pr_files=$(gh pr view "$pr_number" --json files --jq '.files[] | "  • \(.path) (\(.additions)+/\(.deletions)-)"' 2>/dev/null)
      if [ -n "$pr_files" ]; then
        echo "$pr_files"
      else
        echo "  (file list unavailable)"
      fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Nothing to do - issue already complete! 🎉"
    echo ""

    return 0
  fi

  # Phase 0: Pre-start checks
  if ! phase_pre_start_checks "$issue_number"; then
    return 1
  fi

  # Phase 1: Claude workflow (development)
  if ! phase_claude_workflow "$issue_number"; then
    print_error "Workflow phase failed"
    return 1
  fi

  # Phase 2: Push work and wait for review
  if ! phase_create_pr "$issue_number"; then
    print_error "PR phase failed"
    return 1
  fi

  # Phase 3: Assess review and resolve issues (auto-fix loop)
  if ! phase_assess_and_resolve "$issue_number" "$PR_NUMBER"; then
    print_error "Assessment phase failed"
    return 1
  fi

  # Phase 4: Merge PR and update docs
  if ! phase_merge_pr "$issue_number" "$PR_NUMBER"; then
    print_error "Merge phase failed"
    return 1
  fi

  # Phase 5: Completion and notifications
  phase_completion "$issue_number" "$PR_NUMBER"

  return 0
}

# ===================================================================
# ENTRY POINT
# ===================================================================

main() {
  # Parse arguments
  if [ $# -lt 1 ]; then
    echo "Usage: $0 ISSUE_NUMBER [--supervised|--unsupervised|--auto] [--bypass-blockers]"
    echo ""
    echo "Options:"
    echo "  --supervised        Requires manual confirmations (default)"
    echo "  --unsupervised      Fully automated mode (alias: --auto)"
    echo "  --auto              Same as --unsupervised"
    echo "  --bypass-blockers   Report blockers as warnings without stopping the workflow"
    echo ""
    echo "Environment Variables:"
    echo "  WORKFLOW_MODE           supervised or unsupervised (default: supervised)"
    echo "  SLACK_WEBHOOK           Slack webhook URL for notifications"
    echo "  EMAIL_NOTIFICATION_ADDRESS   Email for notifications"
    echo "  RITE_SNS_TOPIC_ARN    AWS SNS topic for SMS notifications"
    echo "  RITE_AWS_PROFILE      AWS profile for credentials (default: default)"
    echo ""
    exit 1
  fi

  local issue_number="$1"
  shift

  # Validate issue number is a positive integer (text descriptions should be resolved by bin/forge)
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [ "$issue_number" -le 0 ] 2>/dev/null; then
    print_error "Invalid issue number: $issue_number (must be positive integer)"
    print_info "Hint: forge accepts text descriptions — they get auto-created as GitHub issues"
    exit 1
  fi

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --supervised)
        WORKFLOW_MODE="supervised"
        ;;
      --unsupervised|--auto)
        WORKFLOW_MODE="unsupervised"
        ;;
      --bypass-blockers)
        BYPASS_BLOCKERS=true
        ;;
      *)
        print_error "Unknown flag: $1"
        exit 1
        ;;
    esac
    shift
  done

  # Check for saved session state from a previous blocker
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    local saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)
    local saved_worktree=$(jq -r '.worktree_path // ""' "$state_file" 2>/dev/null)

    print_info "Found saved session state (blocker: $saved_reason)"

    # Use saved worktree path if it still exists
    if [ -n "$saved_worktree" ] && [ "$saved_worktree" != "null" ] && [ -d "$saved_worktree" ]; then
      WORKTREE_PATH="$saved_worktree"
      export WORKTREE_PATH
      RESUME_MODE=true
      print_success "Resuming from worktree: $WORKTREE_PATH"
    else
      print_warning "Saved worktree no longer exists - starting fresh"
    fi
  fi

  # Initialize session (always create fresh session with current start_time)
  # Even when resuming, we start a fresh Claude process with a new context window,
  # so we reset start_time and issues_completed to track THIS session's usage
  init_session "$WORKFLOW_MODE"

  # Restore worktree path from saved state if resuming
  if [ "$RESUME_MODE" = true ] && [ -n "$WORKTREE_PATH" ]; then
    set_current_worktree "$WORKTREE_PATH"
  fi

  # Run the workflow
  if run_workflow "$issue_number"; then
    print_success "Workflow completed successfully"
    exit 0
  else
    print_error "Workflow failed"
    exit 1
  fi
}

# Run main if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
