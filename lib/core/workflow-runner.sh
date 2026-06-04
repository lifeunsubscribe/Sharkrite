#!/bin/bash
# workflow-runner.sh
# Central orchestrator for automated GitHub workflow with safety mechanisms
# Usage: ./workflow-runner.sh ISSUE_NUMBER [--supervised|--unsupervised] [--resume]

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_WORKFLOW_RUNNER_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_WORKFLOW_RUNNER_LOADED=true

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
source "$RITE_LIB_DIR/utils/pr-summary.sh"
source "$RITE_LIB_DIR/utils/normalize-issue.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/stash-manager.sh"
source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
source "$RITE_LIB_DIR/providers/provider-interface.sh"

# Workflow mode: supervised (requires confirmations) or unsupervised (fully automated)
WORKFLOW_MODE="${WORKFLOW_MODE:-supervised}"
RESUME_MODE=false
BYPASS_BLOCKERS=false

# Phase tracking for graceful exit and resume
CURRENT_PHASE=""
CURRENT_ISSUE=""
CURRENT_PR=""
CURRENT_RETRY=0
INTERRUPT_RECEIVED=false

# Script paths (all in core/)
CLAUDE_WORKFLOW="$RITE_LIB_DIR/core/claude-workflow.sh"
CREATE_PR="$RITE_LIB_DIR/core/create-pr.sh"
ASSESS_RESOLVE="$RITE_LIB_DIR/core/assess-and-resolve.sh"
MERGE_PR="$RITE_LIB_DIR/core/merge-pr.sh"

# ===================================================================
# UTILITY FUNCTIONS
# ===================================================================

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/timeout.sh"
ensure_timeout_cmd

# ===================================================================
# GRACEFUL EXIT HANDLING
# ===================================================================

# Handle Ctrl-C and SIGTERM gracefully
cleanup_on_interrupt() {
  local exit_code="${1:-130}"  # 130 is standard for SIGINT

  # Prevent recursive traps
  if [ "$INTERRUPT_RECEIVED" = true ]; then
    echo ""
    echo "Force exit requested. Exiting immediately."
    # Kill entire process group to terminate all child processes (logging pipeline, etc)
    kill -KILL -- -$$ 2>/dev/null || true
    exit 1
  fi
  INTERRUPT_RECEIVED=true

  echo ""
  echo ""
  print_header "⚡ Interrupt Received - Saving State"

  # Save session state if we have enough context
  if [ -n "$CURRENT_ISSUE" ] && [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
    local phase_info="${CURRENT_PHASE:-unknown}"
    local pr_info="${CURRENT_PR:-none}"

    echo "📍 Current state:"
    echo "   Issue:    #$CURRENT_ISSUE"
    echo "   Phase:    $phase_info"
    echo "   PR:       ${pr_info:-not created yet}"
    echo "   Retry:    ${CURRENT_RETRY:-0}/3"
    echo "   Worktree: $WORKTREE_PATH"
    echo ""

    # Check for uncommitted changes
    cd "$WORKTREE_PATH" 2>/dev/null || true
    local uncommitted=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    if [ "$uncommitted" -gt 0 ]; then
      echo "📝 Found $uncommitted uncommitted change(s)"

      if [ "$WORKFLOW_MODE" = "unsupervised" ]; then
        # Auto-commit in unsupervised mode
        echo "   Auto-committing work in progress..."
        git add -A 2>/dev/null || true
        git commit -m "WIP: Auto-saved on interrupt (phase: $phase_info)" --no-verify 2>/dev/null || true
        echo "   ✅ Changes committed"
      else
        echo "   ⚠️  Uncommitted changes will be preserved in worktree"
        echo "   You can commit them manually before resuming"
      fi
    fi

    # Save state with phase information using extended format
    save_session_state_with_phase "$CURRENT_ISSUE" "interrupted" "$WORKTREE_PATH" "$phase_info" "$pr_info"

    echo ""
    print_success "Session state saved"
    echo ""
    echo "To resume, run:"
    echo "   rite $CURRENT_ISSUE"
    echo ""
  else
    echo "No active workflow state to save."
    echo ""
  fi

  # Return to original directory
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || true

  # Terminate entire process group to ensure all child processes (tee, perl, etc.) are killed.
  # Use SIGTERM first for graceful shutdown, then SIGKILL after brief delay if needed.
  # The negative PID (-$$) sends signal to all processes in the current process group.
  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.5
  kill -KILL -- -$$ 2>/dev/null || true

  exit "$exit_code"
}

# Extended save function that includes phase checkpoint
save_session_state_with_phase() {
  local issue_number="$1"
  local reason="$2"
  local worktree_path="$3"
  local phase="${4:-unknown}"
  local pr_number="${5:-}"

  local data_dir="${RITE_DATA_DIR:-.rite}"
  local state_file="${RITE_PROJECT_ROOT:-.}/${data_dir}/session-state-${issue_number}.json"

  # Ensure data directory exists
  mkdir -p "${RITE_PROJECT_ROOT:-.}/${data_dir}"

  # Get git status safely
  local git_status_b64=""
  local last_commit=""
  if [ -d "$worktree_path" ]; then
    git_status_b64=$(cd "$worktree_path" 2>/dev/null && git status --short | base64 || echo "")
    last_commit=$(cd "$worktree_path" 2>/dev/null && git log -1 --oneline 2>/dev/null || echo "")
  fi

  cat > "$state_file" <<EOF
{
  "saved_at": $(date +%s),
  "saved_at_human": "$(date '+%Y-%m-%d %H:%M:%S')",
  "reason": "$reason",
  "issue_number": "$issue_number",
  "pr_number": "${pr_number:-null}",
  "phase": "$phase",
  "retry_count": ${CURRENT_RETRY:-0},
  "worktree_path": "$worktree_path",
  "workflow_mode": "$WORKFLOW_MODE",
  "git_status": "$git_status_b64",
  "last_commit": "$last_commit"
}
EOF

  echo "💾 State saved: $state_file"
}

# Set up trap handlers (called after sourcing libraries)
setup_interrupt_handlers() {
  trap 'cleanup_on_interrupt 130' INT   # Ctrl-C
  trap 'cleanup_on_interrupt 143' TERM  # kill
  trap 'cleanup_on_interrupt 129' HUP   # Terminal closed
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

  # Early exit if already approved in supervised mode - skip the whole wall
  if [ "$WORKFLOW_MODE" = "supervised" ] && has_approved_blocker "$issue_number" "$blocker_type"; then
    print_info "ℹ️  Blocker $blocker_type (previously approved — continuing)"
    return 0
  fi

  print_header "🚨 BLOCKER DETECTED: $blocker_type"

  echo "$blocker_details"
  echo ""

  # Get urgency level
  local urgency=$(get_blocker_urgency "$blocker_type")
  local blocks_batch=$(is_blocking_batch "$blocker_type")
  local is_batch_mode="${BATCH_MODE:-false}"

  # Save session state WITH phase so resume skips to the right point.
  # Map blocker context to workflow phase (blockers in pre-merge → resume at merge).
  local blocker_phase="unknown"
  case "$context" in
    pre-merge)  blocker_phase="merge" ;;
    pre-start)  blocker_phase="claude-workflow" ;;
    *)          blocker_phase="claude-workflow" ;;
  esac
  save_session_state_with_phase "$issue_number" "$blocker_type" "$worktree_path" "$blocker_phase" "$pr_number"

  # Helper to send notification (deduped, only when workflow stops or bypasses)
  _send_blocker_notif() {
    if [ "$context" = "pre-start" ]; then
      return  # No notification for pre-start failures
    fi
    if has_sent_notification "$issue_number" "blocker:$blocker_type"; then
      return  # Already sent
    fi
    send_blocker_notification "$blocker_type" "$issue_number" "$pr_number" "$worktree_path" "$blocker_details"
    add_sent_notification "$issue_number" "blocker:$blocker_type"
  }

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
      echo "   rite ${issue_number}"
      ;;

    auth_changes|architectural_docs|protected_scripts)
      echo "1. Review the changes shown above"
      # Only show bypass instructions if not already in supervised/bypass mode
      if [ "$WORKFLOW_MODE" != "supervised" ] && [ "$BYPASS_BLOCKERS" != "true" ]; then
        echo "2. To bypass this blocker:"
        echo ""
        echo "   # Supervised mode (bypasses blockers with terminal approval):"
        echo "   rite ${issue_number} --supervised"
        echo ""
        echo "   # Or unsupervised bypass (warnings sent to Slack):"
        echo "   rite ${issue_number} --bypass-blockers"
      fi
      ;;

    infrastructure|database_migration)
      echo "1. Review the changes shown above"
      echo "2. Test locally if needed"
      echo "3. Confirm it's safe to proceed"
      echo "4. Resume workflow:"
      echo ""
      echo "   rite ${issue_number}"
      ;;

    test_failures|build_failures)
      echo "1. Review test/build failures above"
      echo "2. Fix issues locally or in the PR"
      echo "3. Push fixes to the branch"
      echo "4. Resume workflow:"
      echo ""
      echo "   rite ${issue_number}"
      ;;

    critical_issues)
      echo "1. Review security issues in PR"
      echo "2. Fix critical issues on the branch"
      echo "3. Push fixes and wait for new review"
      echo "4. Resume workflow:"
      echo ""
      echo "   rite ${issue_number}"
      ;;

    session_limit|token_limit)
      echo "1. Take a break (session limits reached)"
      echo "2. Resume in fresh session when ready:"
      echo ""
      echo "   rite ${issue_number}"
      ;;

    *)
      echo "1. Review blocker details above"
      echo "2. Take necessary action"
      echo "3. Resume workflow when ready:"
      echo ""
      echo "   rite ${issue_number}"
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
      add_approved_blocker "$issue_number" "$blocker_type"
      print_warning "Blocker acknowledged — continuing workflow"
      return 0
    else
      _send_blocker_notif  # Send notification only when user declines
      print_info "Workflow paused. Run 'rite ${issue_number}' to resume later."
      exit 1
    fi
  fi

  # Unsupervised + --bypass-blockers: bypass all blockers silently
  if [ "$BYPASS_BLOCKERS" = true ]; then
    print_warning "Blocker bypassed (--bypass-blockers): $blocker_type"
    return 0
  fi

  # Unsupervised without bypass: stop on blockers
  _send_blocker_notif  # Send notification when stopping
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

  # Bootstrap internal docs if any required file is missing
  RITE_INTERNAL_DOCS_DIR="${RITE_INTERNAL_DOCS_DIR:-${RITE_PROJECT_ROOT}/.rite/docs}"
  local _needs_bootstrap=false
  for _required_doc in architecture.md api.md security.md changelog.md; do
    if [ ! -f "${RITE_INTERNAL_DOCS_DIR}/${_required_doc}" ]; then
      _needs_bootstrap=true
      break
    fi
  done
  if [ "$_needs_bootstrap" = true ]; then
    source "$RITE_LIB_DIR/core/bootstrap-docs.sh"
  fi

  # Check credentials (blocker handler will print header if needed)
  if ! check_blockers "pre-start"; then
    if ! handle_blocker "pre-start" "$issue_number"; then
      return 1
    fi
  fi

  # Check session limits.
  # Pass cumulative active-work hours (not wall-clock) as the time metric — issue #283.
  # The 4th param (workflow_mode position in check_blockers) is repurposed to carry
  # the current issue number so detect_issue_duration_limit can name the issue in its
  # blocker message. See blocker-rules.sh session-check case for full param mapping.
  local issues_completed
  issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local _cumulative_secs
  _cumulative_secs=$(get_cumulative_work_seconds)
  local cumulative_work_hours=$(( _cumulative_secs / 3600 ))

  if ! check_blockers "session-check" "$issues_completed" "$cumulative_work_hours" "$issue_number"; then
    if ! handle_blocker "session-check" "$issue_number"; then
      return 1
    fi
  fi

  print_success "Pre-start checks passed"
  return 0
}

phase_claude_workflow() {
  local issue_number="$1"

  print_header "Phase 1: Sharkrite Workflow (Development)"

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
    pr_number=$(gh_safe pr list --state open --json number,body --limit 100 | \
      jq --arg issue "$issue_number" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
      '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)

    if [ -n "$pr_number" ]; then
      print_info "Found existing PR #$pr_number for issue #$issue_number"

      # Find worktree for this PR's branch
      pr_branch=$(gh_safe pr view "$pr_number" --json headRefName --jq '.headRefName')
      worktree_path=$(git worktree list | grep "\[$pr_branch\]" | awk '{print $1}' || true)

      if [ -n "$worktree_path" ]; then
        WORKTREE_PATH="$worktree_path"
        set_current_worktree "$WORKTREE_PATH"
        print_success "Using existing worktree: $WORKTREE_PATH"

        # Check for uncommitted changes in the target worktree (exclude symlinks and untracked)
        TARGET_UNCOMMITTED=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | grep -vE "^\?\?" | wc -l | tr -d ' ' || true)
        if [ "$TARGET_UNCOMMITTED" -gt 0 ]; then
          print_warning "Uncommitted changes detected in worktree"

          # Get issue description for relevance analysis
          issue_desc=$(gh_safe issue view "$issue_number" --json title,body --jq '.title + "\n\n" + .body')

          # Get diff of uncommitted changes (exclude untracked files)
          UNCOMMITTED_DIFF=$(git -C "$WORKTREE_PATH" diff HEAD 2>/dev/null || echo "")
          UNCOMMITTED_FILES=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | grep -vE "^\?\?" || echo "")

          if [ -z "$UNCOMMITTED_FILES" ]; then
            echo "   ℹ️  No tracked file changes (only untracked files)"
          else
            # Use Claude CLI to analyze if changes are relevant to the issue
            echo "   ℹ️  Analyzing if changes are relevant to issue #$issue_number..."

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

            load_provider "${RITE_UTILITY_PROVIDER:-claude}"
            RELEVANCE=$(provider_run_classify "$(cat "$PROMPT_FILE")" | grep -oiE "(RELEVANT|UNRELATED)" | head -1 | tr '[:lower:]' '[:upper:]')
            rm -f "$PROMPT_FILE"

            # If Claude CLI failed or returned nothing, fail hard
            if [ -z "$RELEVANCE" ]; then
              echo "   Provider CLI failed to analyze changes"
              echo "   Cannot proceed without determining relevance"
              echo ""
              echo "   Uncommitted changes:"
              echo "$UNCOMMITTED_FILES" | sed 's/^/   /'
              echo ""
              echo "   Please manually commit or stash changes in: $WORKTREE_PATH"
              exit 1
            fi

            echo "   ℹ️  Assessment: $RELEVANCE"

            if [ "$RELEVANCE" = "RELEVANT" ]; then
              # Changes are relevant - commit them
              echo "   ✅ Changes are relevant to issue #$issue_number - committing..."

              cd "$WORKTREE_PATH" || exit 1
              git add -u  # Only add tracked files (not symlinks)
              COMMIT_MSG="wip: auto-commit relevant changes for issue #$issue_number ($(date +%Y-%m-%d))"

              if git commit -m "$COMMIT_MSG" 2>/dev/null; then
                echo "   ✅ Changes committed: $COMMIT_MSG"
              else
                print_error "Failed to commit changes"
                exit 1
              fi
            else
              # Changes are unrelated - stash them, will be popped after workflow completes
              echo "   ℹ️  Changes are unrelated to issue #$issue_number - stashing..."

              cd "$WORKTREE_PATH" || exit 1
              STASH_MSG="Auto-stash unrelated work before issue #$issue_number ($(date +%Y-%m-%d))"

              if create_sharkrite_stash "$STASH_MSG" true; then
                echo "   ✅ Changes stashed: $STASH_MSG"
                echo "   ℹ️  Will be restored after workflow completes"

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

        # Check if PR has actual file changes (not just placeholder commit).
        # Use triple-dot (merge-base diff) so advancing main doesn't false-positive.
        cd "$WORKTREE_PATH" || exit 1
        FILE_CHANGES=$(git diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')

        if [ "$FILE_CHANGES" -gt 0 ]; then
          print_info "Issue #$issue_number has $FILE_CHANGES file(s) changed — skipping development phase"
          print_success "Development phase complete"
          return 0
        else
          # PR exists but has no real work - need to run development
          print_info "Issue #$issue_number has a PR but no implementation yet"
          print_status "Running development phase..."

          # Call claude-workflow.sh to do the actual development work
          if [ "$WORKFLOW_MODE" = "supervised" ]; then
            RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number"
          else
            RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --auto
          fi

          WORKFLOW_EXIT=$?
          if [ $WORKFLOW_EXIT -eq 3 ]; then
            BLOCKER_TYPE=test_failures BLOCKER_DETAILS="Test suite failed during development phase — see output above"
            if ! handle_blocker "pre-merge" "$issue_number"; then
              return 1
            fi
          elif [ $WORKFLOW_EXIT -eq 4 ]; then
            # No work produced — retry once
            print_warning "Development session produced no changes — retrying once"
            echo ""
            if [ "$WORKFLOW_MODE" = "supervised" ]; then
              RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number"
            else
              RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --auto
            fi
            WORKFLOW_EXIT=$?
            if [ $WORKFLOW_EXIT -eq 4 ]; then
              print_error "Development produced no changes after retry"
              print_info "Issue may need manual investigation or a clearer description"
              # Clean up empty draft PR
              if [ -n "${pr_number:-}" ]; then
                local _pr_adds
                _pr_adds=$(gh_safe pr view "$pr_number" --json additions --jq '.additions')
                _pr_adds="${_pr_adds:-0}"
                if [ "${_pr_adds:-0}" -eq 0 ]; then
                  gh_safe pr close "$pr_number" --delete-branch 2>/dev/null || true
                  print_info "Closed empty draft PR #$pr_number"
                fi
              fi
              return 1
            elif [ $WORKFLOW_EXIT -ne 0 ] && [ $WORKFLOW_EXIT -ne 3 ]; then
              print_error "Development workflow failed on retry (exit code: $WORKFLOW_EXIT)"
              return $WORKFLOW_EXIT
            fi
          elif [ $WORKFLOW_EXIT -ne 0 ]; then
            print_error "Development workflow failed"
            return $WORKFLOW_EXIT
          fi

          # Re-check if development actually produced work
          local post_dev_changes
          post_dev_changes=$(git -C "$WORKTREE_PATH" diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')
          if [ "${post_dev_changes:-0}" -eq 0 ]; then
            print_warning "No work was produced in the development phase"
            print_info "Aborting workflow — nothing to push or review"
            return 1
          fi

          print_success "Development phase complete"
          return 0
        fi
      else
        # PR exists but no worktree (e.g., after undo reverted PR to draft and removed worktree)
        # Run development to create worktree and implement the fix
        print_info "Issue #$issue_number has a PR but worktree not found — running development"

        local workflow_exit=0
        set +e
        if [ "$WORKFLOW_MODE" = "supervised" ]; then
          RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number"
        else
          RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --auto
        fi
        workflow_exit=$?
        set -e

        # Detect worktree created by claude-workflow.sh before handling any blocker,
        # so the worktree path is saved in session state for branch-update on resume.
        if detect_pr_for_issue "$issue_number" 2>/dev/null; then
          detect_worktree_for_pr "$PR_NUMBER" || true
        fi
        if [ -z "${WORKTREE_PATH:-}" ]; then
          local _main_wt=$(git rev-parse --show-toplevel)
          WORKTREE_PATH=$(git worktree list | awk '{print $1}' | grep -v "^${_main_wt}$" | grep -E "(issue.?${issue_number}|#${issue_number})" | head -1 || true)
        fi
        if [ -n "${WORKTREE_PATH:-}" ]; then
          set_current_worktree "$WORKTREE_PATH"
        fi

        if [ $workflow_exit -eq 3 ]; then
          BLOCKER_TYPE=test_failures BLOCKER_DETAILS="Test suite failed during development phase — see output above"
          if ! handle_blocker "pre-merge" "$issue_number"; then
            return 1
          fi
        elif [ $workflow_exit -ne 0 ]; then
          print_error "Development workflow failed (exit code: $workflow_exit)"
          return $workflow_exit
        fi
      fi
    else
      print_info "Starting fresh on issue #${issue_number}"

      # Call claude-workflow.sh to create worktree and do development
      # claude-workflow.sh handles detecting uncommitted changes internally
      # (its SKIP_CLAUDE flag triggers when changes exist in the worktree)
      # RITE_ORCHESTRATED tells claude-workflow.sh to skip its internal PR/review
      # workflow — those are handled by Phase 2/3 of the orchestrator.
      local workflow_exit=0
      set +e
      if [ "$WORKFLOW_MODE" = "supervised" ]; then
        RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number"
      else
        RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --auto
      fi
      workflow_exit=$?
      set -e

      # Extract worktree path via PR branch name (reliable with parallel runs)
      # claude-workflow.sh creates a draft PR early, so we can find it by issue link.
      # Done BEFORE the blocker check so the path is saved in session state on test failure.
      if detect_pr_for_issue "$issue_number"; then
        detect_worktree_for_pr "$PR_NUMBER" || true
      fi

      # Fallback: match issue number in worktree path.
      # Handles batch naming like _b98-109-112- (matches -N- or _bN-) and
      # simple naming like issue-N or #N.
      if [ -z "${WORKTREE_PATH:-}" ]; then
        MAIN_WORKTREE=$(git rev-parse --show-toplevel)
        WORKTREE_PATH=$(git worktree list | awk '{print $1}' | grep -v "^${MAIN_WORKTREE}$" | \
          grep -E "(issue.?${issue_number}|#${issue_number}|[-_]${issue_number}[-_]|[-_]${issue_number}$)" | head -1 || true)
      fi

      # Last resort: read handoff file written by claude-workflow.sh
      if [ -z "${WORKTREE_PATH:-}" ] && [ -n "${RITE_STATE_DIR:-}" ]; then
        local _handoff_file="${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"
        if [ -f "$_handoff_file" ]; then
          WORKTREE_PATH=$(cat "$_handoff_file" 2>/dev/null || echo "")
          rm -f "$_handoff_file"
        fi
      fi

      if [ -n "${WORKTREE_PATH:-}" ]; then
        set_current_worktree "$WORKTREE_PATH"
      fi

      if [ $workflow_exit -eq 3 ]; then
        BLOCKER_TYPE=test_failures BLOCKER_DETAILS="Test suite failed during development phase — see output above"
        if ! handle_blocker "pre-merge" "$issue_number"; then
          return 1
        fi
      elif [ $workflow_exit -eq 4 ]; then
        # Exit 4 = session completed but no work produced. Retry once.
        print_warning "Development session produced no changes — retrying once"
        echo ""

        set +e
        if [ "$WORKFLOW_MODE" = "supervised" ]; then
          RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number"
        else
          RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --auto
        fi
        workflow_exit=$?
        set -e

        # Re-discover worktree after retry
        if detect_pr_for_issue "$issue_number"; then
          detect_worktree_for_pr "$PR_NUMBER" || true
        fi
        if [ -z "${WORKTREE_PATH:-}" ]; then
          MAIN_WORKTREE=$(git rev-parse --show-toplevel)
          WORKTREE_PATH=$(git worktree list | awk '{print $1}' | grep -v "^${MAIN_WORKTREE}$" | \
            grep -E "(issue.?${issue_number}|#${issue_number}|[-_]${issue_number}[-_]|[-_]${issue_number}$)" | head -1 || true)
        fi

        if [ $workflow_exit -eq 4 ]; then
          print_error "Development produced no changes after retry"
          print_info "Issue may need manual investigation or a clearer description"

          # Clean up empty draft PR so it doesn't cause stale worktree loops on next run
          if [ -n "${PR_NUMBER:-}" ]; then
            local _pr_additions
            _pr_additions=$(gh_safe pr view "$PR_NUMBER" --json additions --jq '.additions')
            _pr_additions="${_pr_additions:-0}"
            if [ "${_pr_additions:-0}" -eq 0 ]; then
              gh_safe pr close "$PR_NUMBER" --delete-branch 2>/dev/null || true
              print_info "Closed empty draft PR #$PR_NUMBER"
            fi
          fi
          return 1
        elif [ $workflow_exit -eq 3 ]; then
          BLOCKER_TYPE=test_failures BLOCKER_DETAILS="Test suite failed during development phase — see output above"
          if ! handle_blocker "pre-merge" "$issue_number"; then
            return 1
          fi
        elif [ $workflow_exit -eq 2 ]; then
          # Divergence resolved by pulling foreign commits — push succeeded inside handler.
          # Treat as dev-phase success; Phase 2 will detect the stale review and regenerate.
          print_info "Divergence resolved during post-dev push (retry) — continuing to Phase 2"
        elif [ $workflow_exit -ne 0 ]; then
          print_error "Development workflow failed on retry (exit code: $workflow_exit)"
          return $workflow_exit
        fi
      elif [ $workflow_exit -eq 2 ]; then
        # Divergence resolved by pulling foreign commits — push succeeded inside handler.
        # Treat as dev-phase success; Phase 2 will detect the stale review and regenerate.
        print_info "Divergence resolved during post-dev push — continuing to Phase 2"
      elif [ $workflow_exit -ne 0 ]; then
        print_error "Development workflow failed (exit code: $workflow_exit)"
        return $workflow_exit
      fi

      if [ -z "${WORKTREE_PATH:-}" ]; then
        print_error "Worktree not found after claude-workflow.sh"
        print_info "Available worktrees:"
        git worktree list
        return 1
      fi

      set_current_worktree "$WORKTREE_PATH"

      # Verify development actually produced work (file changes vs main).
      # Use triple-dot (merge-base diff) so advancing main doesn't false-positive.
      local file_changes
      file_changes=$(git -C "$WORKTREE_PATH" diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')

      if [ "$file_changes" -eq 0 ]; then
        print_warning "No work was produced in the development phase"
        print_info "claude-workflow.sh exited with code $workflow_exit but made no file changes"
        print_info "Aborting workflow — nothing to push or review"
        return 1
      fi

      print_info "Development produced $file_changes file(s) changed"
    fi
  fi

  print_success "Development phase complete"
  return 0
}

phase_create_pr() {
  local issue_number="$1"
  local loop_mode="${2:-}"

  # Compact header on fix loop iterations (--loop), full header on normal entry/resume
  if [ "$loop_mode" = "--loop" ]; then
    echo ""
    print_status "Fix loop: pushing fixes and re-reviewing..."
    echo ""
  else
    print_header "Phase 2: Push Work and Wait for Review"
  fi

  cd "$WORKTREE_PATH"

  # Get OPEN PR for current branch (gh pr list returns open PRs only;
  # gh pr view returns closed PRs too, which causes wrong-PR-number bugs
  # when a previous draft was closed during a no-work cleanup)
  local branch_name=$(git rev-parse --abbrev-ref HEAD)
  PR_NUMBER=$(gh_safe pr list --head "$branch_name" --json number --jq '.[0].number')

  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    print_error "No open PR found for branch '$branch_name'"
    return 1
  fi

  # Check if a valid REVIEW already exists (newer than latest commit).
  # If so, skip the entire PR phase — nothing to push, nothing to review.
  #
  # IMPORTANT: Use LOCAL git commit timestamps, not GitHub API commits.
  # After a fix loop, claude-workflow.sh pushes commits, but the GitHub API
  # has eventual consistency — the commits list may not include the new commit
  # yet, making the old review appear "current". This caused an infinite fix
  # loop: fix → skip push/review → re-assess stale review → find same issue
  # → fix again. Using local git log avoids this race condition entirely.
  #
  # Only match actual review comments (sharkrite-local-review marker),
  # NOT assessment comments (sharkrite-assessment marker) or other bot comments.
  # Exclude mainline sync merge commits (e.g., GitHub "Update branch" button)
  # from the comparison — they don't change the PR's work scope.
  # Phase 4 (merge) handles divergence resolution separately.
  local local_head=$(git rev-parse HEAD 2>/dev/null || echo "")
  local remote_head=$(git rev-parse "origin/$branch_name" 2>/dev/null || echo "")

  if [ "$local_head" = "$remote_head" ]; then
    # All commits already pushed — check review currency using LOCAL commit time
    # (avoids GitHub API eventual consistency issues).
    #
    # IMPORTANT: Output commit time in UTC to match the GitHub API's UTC timestamps.
    # git log --format=%cI outputs local timezone (e.g., 2026-02-17T19:45-07:00),
    # while API returns UTC (2026-02-18T02:45Z). String comparison of mixed timezones
    # gives wrong results (different calendar dates for the same instant).
    local latest_local_commit_time
    get_latest_work_commit_time "." "$PR_NUMBER"
    latest_local_commit_time="$LATEST_COMMIT_TIME"

    local latest_review_time _jq_latest_review_time
    _jq_latest_review_time="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].createdAt // \"\""
    latest_review_time=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_jq_latest_review_time")

    if [ -n "$latest_review_time" ] && [ -n "$latest_local_commit_time" ]; then
      # Compare as epoch seconds (not lexicographic) for reliable cross-format comparison.
      # Matches the epoch comparison in assess-and-resolve.sh.
      local review_epoch commit_epoch
      review_epoch=$(iso_to_epoch "$latest_review_time")
      commit_epoch=$(iso_to_epoch "$latest_local_commit_time")
      if [ "$review_epoch" -gt 0 ] && [ "$commit_epoch" -gt 0 ] && [ "$review_epoch" -gt "$commit_epoch" ]; then
        print_info "Issue #$issue_number already has a current review — skipping push/review phase"
        return 0
      fi
    fi
  else
    print_info "Unpushed commits detected — proceeding to push and review"
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
  if [ $create_pr_exit -eq 2 ]; then
    # Divergence resolved but needs re-review (foreign commits pulled in)
    print_info "Divergence resolved — review cycle will re-run in Phase 3"
    return 0  # Fall through to Phase 3 naturally
  elif [ $create_pr_exit -eq 5 ]; then
    # Usage cap reached — propagate exit 5 so batch can abort cleanly
    return 5
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

  # Track retry count globally for interrupt handler
  CURRENT_RETRY="$retry_count"

  # Compact header on fix loop iterations (retry > 0), full header on normal entry/resume
  if [ "$retry_count" -gt 0 ]; then
    echo ""
    print_status "Fix loop ($retry_count/$max_retries): assessing review..."
    echo ""
  else
    print_header "Phase 3: Assess Review and Resolve Issues"
  fi

  # Check if a passing assessment already exists (idempotency on resume).
  # Only check on first entry (retry_count=0) — retries should always re-assess.
  if [ "$retry_count" -eq 0 ]; then
    # Fetch assessment AND check for existing follow-up issue marker in one call
    local pr_assess_state _jq_pr_assess_state
    _jq_pr_assess_state="{assessment: ([.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].body // \"\"), has_followup: ([.comments[] | select(.body | contains(\"${RITE_MARKER_FOLLOWUP}:\"))] | length > 0)}"
    pr_assess_state=$(gh_safe pr view "$pr_number" --json comments --jq "$_jq_pr_assess_state")
    pr_assess_state="${pr_assess_state:-"{}"}"

    local existing_assessment=$(echo "$pr_assess_state" | jq -r '.assessment // ""' 2>/dev/null)
    local has_followup=$(echo "$pr_assess_state" | jq -r '.has_followup // false' 2>/dev/null)

    if [ -n "$existing_assessment" ] && [ "$existing_assessment" != "" ]; then
      local existing_actionable=$(echo "$existing_assessment" | grep -c "^### .* - ACTIONABLE_NOW" || true)
      local existing_later=$(echo "$existing_assessment" | grep -c "^### .* - ACTIONABLE_LATER" || true)

      if [ "$existing_actionable" -eq 0 ]; then
        # Assessment passes — but check if ACTIONABLE_LATER items need tech-debt issues
        if [ "$existing_later" -gt 0 ] && [ "$has_followup" != "true" ]; then
          print_info "Assessment passes but $existing_later ACTIONABLE_LATER items need tech-debt issues — running Phase 3"
        else
          print_info "Issue #$issue_number already has a passing assessment (0 ACTIONABLE_NOW) — skipping assessment phase"
          [ "$existing_later" -gt 0 ] && print_status "  ($existing_later ACTIONABLE_LATER items already have follow-up issues)"
          return 0
        fi
      else
        print_info "Existing assessment has $existing_actionable ACTIONABLE_NOW items — re-entering fix loop"
      fi
    fi
  fi

  if [ $retry_count -gt 0 ]; then
    print_info "Retry attempt $retry_count of $max_retries"
  fi

  # Check if a follow-up issue was created in a previous run and is now resolved
  # This allows the workflow to skip directly to merge if resuming after manual resolution
  local followup_marker
  followup_marker=$(gh_safe pr view "$pr_number" --json comments --jq '.comments[].body' | grep -oE "${RITE_MARKER_FOLLOWUP}:[0-9]+" | tail -1 || true)
  if [ -n "$followup_marker" ]; then
    local followup_issue_num=$(echo "$followup_marker" | cut -d: -f2)
    local followup_state
    followup_state=$(gh_safe issue view "$followup_issue_num" --json state --jq '.state')

    if [ "$followup_state" = "CLOSED" ]; then
      print_success "✅ Follow-up issue #$followup_issue_num has been resolved"
      print_info "Skipping assessment loop - proceeding to merge"
      return 0
    elif [ -n "$followup_state" ]; then
      print_info "📋 Follow-up issue #$followup_issue_num exists (state: $followup_state)"
      print_info "Workflow will continue assessment to check if PR is ready to merge"
    fi
  fi

  # Mid-run drift check: detect if main has advanced since phase 1 (development).
  # Wide-surface PRs (touching many files) spend 1-2h in phases 1-3.  By the time
  # phase 4 (merge) fires, main may have moved 10-19 commits ahead, causing the
  # pre-merge auto-merge to fail on content conflicts after all the Claude time is spent.
  #
  # Fix: rebase proactively at the START of phase 3 (and on each fix iteration).
  # If drift <= threshold (default 5): rebase silently.
  # If drift >  threshold or conflicts: abort HERE, before generating a review.
  #
  # Implementation note: call from WORKTREE_PATH context only — WORKTREE_PATH must be set.
  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    local _mid_rebase_branch
    _mid_rebase_branch=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -n "$_mid_rebase_branch" ] && [ "$_mid_rebase_branch" != "main" ] && [ "$_mid_rebase_branch" != "master" ]; then
      local _mid_rebase_result=0
      check_and_rebase_against_main \
        "$WORKTREE_PATH" \
        "$_mid_rebase_branch" \
        "$issue_number" \
        "${pr_number:-}" \
        "$WORKFLOW_MODE" || _mid_rebase_result=$?
      if [ "$_mid_rebase_result" -ne 0 ]; then
        # Drift too large or conflicts: abort before spending Claude time on a review
        print_error "Phase 3 aborted: mid-run drift cannot be resolved automatically"
        print_info "Run 'rite ${issue_number} --supervised' to resolve conflicts manually"
        return 1
      fi
    fi
  fi

  # Data flow: assess-and-resolve.sh outputs filtered review to stdout (no temp files)
  # We capture stdout and pipe directly to claude-workflow.sh for fixes

  cd "$WORKTREE_PATH"

  # NOTE: Blockers are checked in phase_merge_pr (pre-merge gate), not here.
  # This lets the review/assessment loop run uninterrupted, giving the user
  # full context about what the PR contains before the blocker approval prompt.

  # Call assess-and-resolve.sh (pass issue number and retry count)
  # This will categorize ALL review issues and either:
  # - exit 0: actionable_count == 0 → merge
  # - exit 1: retry >= 3 AND CRITICAL+ACTIONABLE → create follow-up, block merge
  # - exit 2: actionable_count > 0 AND retry < 3 → loop to fix (outputs review to stdout)
  # - exit 3: review is stale → route back to Phase 2 for fresh review
  # In AUTO_MODE with CRITICAL issues, it will output filtered review content to stdout
  # and exit with code 2 (no temp files needed - we capture stdout directly)

  # Run assessment and capture stdout (for exit code 2) and stderr (for errors)
  local review_content=""
  local assess_stdout=$(mktemp)
  local assess_stderr=$(mktemp)

  # Show assessment header with progress indicator
  print_header "📊 Review Assessment — Issue #$issue_number"
  print_status "Analyzing issue #$issue_number (PR #$pr_number)..."
  local assess_start_time=$(date +%s)

  set +e  # Temporarily disable exit-on-error to capture exit code properly
  # Use process substitution to show stderr in real-time while capturing it
  # This lets Claude assessment output stream to terminal as it runs
  if [ "$WORKFLOW_MODE" = "supervised" ]; then
    "$ASSESS_RESOLVE" "$pr_number" "$issue_number" "$retry_count" > "$assess_stdout" 2> >(tee "$assess_stderr" >&2)
  else
    "$ASSESS_RESOLVE" "$pr_number" "$issue_number" "$retry_count" --auto > "$assess_stdout" 2> >(tee "$assess_stderr" >&2)
  fi
  local assessment_result=$?
  # Wait for tee subprocesses to finish writing
  wait
  set -e  # Re-enable exit-on-error

  # Display elapsed time
  local assess_end_time=$(date +%s)
  local assess_elapsed=$((assess_end_time - assess_start_time))
  print_info "Assessment completed in ${assess_elapsed}s"

  # Read stdout into variable (used for exit code 2 - fixes needed)
  review_content=$(cat "$assess_stdout")

  # Extract decision counts from stdout (when exit code 2)
  local now_count=0
  local later_count=0
  local dismissed_count=0

  if [ -n "$review_content" ]; then
    # Match structured headers only (^### Title - STATE) to avoid
    # counting mentions of state names in reasoning text
    now_count=$(echo "$review_content" | grep -c "^### .* - ACTIONABLE_NOW" || true)
    later_count=$(echo "$review_content" | grep -c "^### .* - ACTIONABLE_LATER" || true)
    dismissed_count=$(echo "$review_content" | grep -c "^### .* - DISMISSED" || true)
  fi

  # Keep stderr for potential error display, cleanup stdout
  rm -f "$assess_stdout"

  if [ $assessment_result -eq 2 ]; then
    # Critical issues found - need to fix and restart PR cycle
    print_warning "Critical issues found - invoking Sharkrite to fix"

    if [ $now_count -gt 0 ] || [ $later_count -gt 0 ] || [ $dismissed_count -gt 0 ]; then
      print_info "Decision breakdown:"
      print_status "  • ACTIONABLE_NOW: $now_count items (fix now)"
      [ $later_count -gt 0 ] && print_status "  • ACTIONABLE_LATER: $later_count items (deferred)"
      [ $dismissed_count -gt 0 ] && print_status "  • DISMISSED: $dismissed_count items (ignored)"
    fi

    # Check if we've hit max retries
    if [ $retry_count -ge $max_retries ]; then
      print_error "Maximum retry attempts ($max_retries) reached - manual intervention required"
      print_warning "Creating follow-up issue for manual resolution"

      # Call assess-and-resolve to create follow-up issue
      # IMPORTANT: Pass retry_count so it knows this is final (skips stale check, creates issue)
      print_info "Creating follow-up issue with remaining items"
      "$ASSESS_RESOLVE" "$pr_number" "$issue_number" "$retry_count"

      return 1
    fi

    # Call claude-workflow.sh in fix mode to address the review issues
    # Pass PR number so it can fetch the latest assessment from PR comments
    cd "$WORKTREE_PATH" || return 1

    if [ -n "$review_content" ]; then
      # Assessment is already posted as a PR comment (<!-- sharkrite-assessment --> marker).
      # Pass PR number so claude-workflow.sh can fetch the latest assessment directly.
      print_info "Assessment available as PR #$pr_number comment (retry $retry_count)"

      # Respect supervised/unsupervised mode
      if [ "$WORKFLOW_MODE" = "supervised" ]; then
        RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --fix-review --pr-number "$pr_number"
      else
        RITE_ORCHESTRATED=true "$CLAUDE_WORKFLOW" "$issue_number" --fix-review --pr-number "$pr_number" --auto
      fi
      local fix_result=$?

      if [ $fix_result -eq 3 ]; then
        # Test failure during fix-review — route through blocker handler
        BLOCKER_TYPE=test_failures BLOCKER_DETAILS="Test suite failed after review fixes — see output above"
        if ! handle_blocker "pre-merge" "$issue_number" "$pr_number"; then
          return 1
        fi
      elif [ $fix_result -eq 5 ]; then
        # Usage cap reached during fix-review push — propagate so batch aborts cleanly
        print_warning "Usage cap reached during fix-review — aborting batch"
        return 5
      elif [ $fix_result -eq 2 ]; then
        # Divergence was resolved by pulling foreign commits (handle_push_divergence exit 2).
        # The push succeeded inside the handler; the HEAD now includes foreign commits.
        # Fall through to phase_create_pr below so a fresh review covers the combined state.
        print_info "Divergence resolved during fix-review — re-entering review cycle"
      elif [ $fix_result -ne 0 ]; then
        print_error "Claude workflow fix mode failed (exit code: $fix_result)"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Troubleshooting:"
        echo "  1. Check the latest assessment comment on PR #$pr_number"
        echo "  2. The Claude session may have timed out or errored"
        echo "  3. Run manually to debug:"
        echo "     cd $WORKTREE_PATH"
        echo "     gh pr view $pr_number --json comments --jq '[.comments[] | select(.body | contains(\"${RITE_MARKER_ASSESSMENT}\"))] | .[-1].body'"
        echo "     $CLAUDE_WORKFLOW $issue_number --fix-review --pr-number $pr_number"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        return 1
      fi
    else
      print_error "No review content captured from assess-and-resolve"
      return 1
    fi

    # After fixes, restart from Phase 2 (create/update PR)
    if ! phase_create_pr "$issue_number" --loop; then
      print_error "Failed to push fixes and regenerate review"
      return 1
    fi

    # Increment retry count and recurse (compact headers via retry_count > 0)
    local next_retry=$((retry_count + 1))
    phase_assess_and_resolve "$issue_number" "$PR_NUMBER" "$next_retry"
    return $?
  elif [ $assessment_result -eq 3 ]; then
    # Review is stale — route back to Phase 2 for push + fresh review,
    # then re-enter Phase 3 to assess the new review.
    # Guard against infinite stale→Phase2→stale loops (max 2 reroutes).
    local stale_reroute_count="${STALE_REROUTE_COUNT:-0}"
    if [ "$stale_reroute_count" -ge 2 ]; then
      print_error "Stale review loop detected — rerouted $stale_reroute_count times without generating a fresh review"
      print_info "The review at $PR_NUMBER may need manual regeneration:"
      print_status "  rite review $PR_NUMBER"
      rm -f "$assess_stderr"
      return 1
    fi
    export STALE_REROUTE_COUNT=$((stale_reroute_count + 1))

    print_warning "Review is stale — routing back to Phase 2 for fresh review (reroute $((stale_reroute_count + 1))/2)"
    rm -f "$assess_stderr"

    if ! phase_create_pr "$issue_number" --loop; then
      print_error "Failed to regenerate review during stale reroute"
      return 1
    fi

    # Validate that a fresh review was actually posted before re-entering assessment.
    # Without this, a silent review generation failure causes assess-and-resolve to
    # see the same stale review → exit 3 again → infinite reroute loop.
    local _post_reroute_review_time _jq_reroute_review_time
    _jq_reroute_review_time="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].createdAt // \"\""
    _post_reroute_review_time=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_jq_reroute_review_time")

    # Ensure commit time is available (phase_create_pr may skip computing it)
    if [ -z "${LATEST_COMMIT_TIME:-}" ]; then
      get_latest_work_commit_time "$WORKTREE_PATH" "$PR_NUMBER"
    fi

    if [ -n "$_post_reroute_review_time" ] && [ -n "${LATEST_COMMIT_TIME:-}" ]; then
      local _rr_review_epoch _rr_commit_epoch
      _rr_review_epoch=$(iso_to_epoch "$_post_reroute_review_time")
      _rr_commit_epoch=$(iso_to_epoch "$LATEST_COMMIT_TIME")
      if [ "$_rr_review_epoch" -gt 0 ] && [ "$_rr_commit_epoch" -gt 0 ] && \
         [ "$_rr_review_epoch" -le "$_rr_commit_epoch" ]; then
        print_error "Review regeneration did not produce a fresh review (review still older than latest commit)"
        print_info "Review: $_post_reroute_review_time  Commit: $LATEST_COMMIT_TIME"
        print_info "Manual regeneration: rite $issue_number --review-latest"
        return 1
      fi
    fi

    phase_assess_and_resolve "$issue_number" "$PR_NUMBER" "$retry_count"
    return $?
  elif [ $assessment_result -ne 0 ]; then
    print_error "Assessment failed with exit code: $assessment_result"
    echo ""
    echo "To re-run manually:"
    echo "  cd $WORKTREE_PATH"
    echo "  $ASSESS_RESOLVE $pr_number $issue_number $retry_count"
    echo ""
    rm -f "$assess_stderr"
    return 1
  fi
  rm -f "$assess_stderr"

  # Assessment complete - decision already shown in Phase 3 header
  # (No redundant summary needed - assess-and-resolve.sh already printed decision box)

  return 0
}

phase_merge_pr() {
  local issue_number="$1"
  local pr_number="$2"

  print_header "Phase 4: Merge and Update Docs"

  cd "$WORKTREE_PATH"

  # Show a brief changes summary so the user knows what's about to be merged
  local _pr_info
  _pr_info=$(gh_safe pr view "$pr_number" --json title,body)
  _pr_info="${_pr_info:-"{}"}"
  local _pr_title=$(echo "$_pr_info" | jq -r '.title // ""')
  local _pr_body=$(echo "$_pr_info" | jq -r '.body // ""')

  if [ -n "$_pr_title" ]; then
    echo ""
    echo "📋 PR #$pr_number: $_pr_title"

    local _summary
    _summary=$(extract_changes_summary "$_pr_body" 2>/dev/null) || _summary=""

    if [ -n "$_summary" ]; then
      # Display the marked section (skip the "## Changes" header — we have our own chrome)
      echo "$_summary" | grep -v "^## Changes" | grep -v "^### Commits" | grep -v "^$" | head -15 | sed 's/^/   /'
    else
      # Fallback for PRs created before this change
      local _changed_files
      _changed_files=$(gh_safe pr view "$pr_number" --json files --jq '.files[].path')
      local _file_count=$(echo "$_changed_files" | grep -c '.' || true)
      local _commit_count
      _commit_count=$(gh_safe pr view "$pr_number" --json commits --jq '.commits | length')
      _commit_count="${_commit_count:-?}"
      echo "   $_file_count file(s), $_commit_count commit(s)"
      if [ "$_file_count" -le 10 ] && [ -n "$_changed_files" ]; then
        echo "$_changed_files" | sed 's/^/   • /'
      else
        echo "$_changed_files" | head -8 | sed 's/^/   • /'
        echo "   ... and $((_file_count - 8)) more"
      fi
    fi
    echo ""
  fi

  # Pre-merge blocker gate: check for infrastructure, auth, migration changes etc.
  # This runs AFTER review/assessment so the user has full context for the decision.
  if ! check_blockers "pre-merge" "$pr_number" "$issue_number" "$WORKFLOW_MODE"; then
    if ! handle_blocker "pre-merge" "$issue_number" "$pr_number"; then
      return 1
    fi
  fi

  # Pre-merge head verification: ensure PR head hasn't changed since assessment.
  # Catches foreign commits pushed between Phase 3 (assess) and Phase 4 (merge).
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"

  local local_head
  local_head=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")
  local auto_flag="false"
  [ "$WORKFLOW_MODE" = "unsupervised" ] && auto_flag="true"

  if [ -n "$local_head" ] && ! verify_pr_head "$pr_number" "$local_head"; then
    print_warning "PR head changed since assessment — checking for foreign commits"
    local branch_name
    branch_name=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [ -n "$branch_name" ] && detect_divergence "$branch_name"; then
      local div_result=0
      handle_push_divergence "$branch_name" "$issue_number" "$pr_number" "$auto_flag" || div_result=$?

      if [ $div_result -eq 2 ]; then
        # Need re-review — go back to Phase 2→3
        print_info "Re-entering review loop due to foreign commits"
        phase_create_pr "$issue_number"
        phase_assess_and_resolve "$issue_number" "$PR_NUMBER" 0
        # Fall through to retry merge after re-assessment
      elif [ $div_result -eq 5 ]; then
        # Usage cap reached during conflict resolution — propagate so batch aborts cleanly
        print_warning "Usage cap reached during merge-time divergence resolution — aborting batch"
        return 5
      elif [ $div_result -ne 0 ]; then
        print_error "Cannot merge — PR head diverged and could not be resolved"
        return 1
      fi
      # div_result=0: resolved, continue to merge
    fi
  fi

  # merge-pr.sh will:
  # - Update security guide with findings from PR review
  # - Create follow-up issues if needed
  # - Merge PR
  # - Clean up worktree
  # - Send notifications
  #
  # Always pass --auto when orchestrated. The blocker gate above is the real
  # decision point; by this line, merge is approved. merge-pr.sh's interactive
  # prompts (proceed with merge?, delete branch?, close issue?) are redundant.
  "$MERGE_PR" "$pr_number" --auto

  local merge_result=$?

  if [ $merge_result -eq 6 ]; then
    # Merge succeeded but cleanup failed — return 6 so batch reporter knows work landed
    print_warning "Merge succeeded but cleanup encountered errors"
    return 6
  elif [ $merge_result -eq 5 ]; then
    # Usage cap reached during merge-pr.sh divergence resolution — propagate so batch aborts
    print_warning "Usage cap reached during merge — aborting batch"
    return 5
  elif [ $merge_result -ne 0 ]; then
    # Merge actually failed — no work on remote
    print_error "Merge failed"
    return 1
  fi

  # merge-pr.sh ran inside the worktree and removed it. Our shell's CWD is now a
  # deleted directory. Restore a valid CWD before anything else runs — `git -C`
  # protects explicit git invocations, but `gh` shells out to git internally for
  # repo detection and does NOT honor -C, so `gh_safe pr view` below fails with
  # `fatal: Unable to read current working directory` if we skip this cd.
  # Regression: PR #211 fixed this for assess-documentation.sh but not for the
  # phase_merge_pr code path; see tests/regression/cleanup-cwd-after-worktree-removal.bats.
  cd "$RITE_PROJECT_ROOT" || cd /

  # Prune stale worktree metadata — git worktree remove sometimes leaves
  # entries in .git/worktrees/, causing branch -D to fail with "checked out at".
  git -C "$RITE_PROJECT_ROOT" worktree prune 2>/dev/null || true

  local _merged_branch
  _merged_branch=$(gh_safe pr view "$pr_number" --json headRefName --jq '.headRefName')
  if [ -n "$_merged_branch" ] && git -C "$RITE_PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$_merged_branch" 2>/dev/null; then
    git -C "$RITE_PROJECT_ROOT" branch -D "$_merged_branch" 2>/dev/null || true
  fi

  print_success "Issue #${issue_number} merged successfully (PR #${pr_number})"
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

  # phase_merge_pr removes the worktree (via merge-pr.sh) but the caller's cwd
  # is still set to $WORKTREE_PATH, which no longer exists.  Restore to the main
  # repo root before returning so any downstream phase (phase_completion, etc.)
  # can run gh/git commands without inheriting a deleted directory as cwd.
  # This mirrors the pattern in merge-pr.sh:981 (cd-before-remove inside the
  # script that does the removal), applied at the next layer up.
  # Contract: when phase_merge_pr returns 0, cwd == $RITE_PROJECT_ROOT.
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || cd "$(git -C "$RITE_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || true

  return 0
}

phase_completion() {
  local issue_number="$1"
  local pr_number="$2"

  # Defense-in-depth: phase_merge_pr removes the worktree and restores cwd to
  # $RITE_PROJECT_ROOT before returning (Option A fix), but any other path that
  # leaves the process in a deleted directory would also break the gh calls below.
  # Explicitly cd to the repo root here so this phase is robust against any
  # upstream cwd mismatch — not just the post-merge case.
  # Related: issue #161 (assess-documentation.sh cwd guard), issue #235 (this fix).
  # See docs/architecture/behavioral-design.md → "Phase Handoff cwd Invariants".
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || true

  print_header "Phase 5: Completion"

  # Get PR details for notification
  local pr_title
  pr_title=$(gh_safe pr view "$pr_number" --json title --jq '.title')
  pr_title="${pr_title:-Unknown}"
  local files_changed
  files_changed=$(gh_safe pr view "$pr_number" --json files --jq '.files | length')
  files_changed="${files_changed:-?}"

  # Check if follow-up issues were created
  local followup_issues
  followup_issues=$(gh_safe issue list --label "follow-up" --label "parent:#${issue_number}" --json number --jq '. | length')
  followup_issues="${followup_issues:-0}"

  # Send completion notification
  send_completion_notification "$issue_number" "$pr_number" "$pr_title" "$files_changed" "$followup_issues"

  # Show session summary
  echo ""
  get_session_summary

  # Show rtk token savings if available
  local rtk_summary
  rtk_summary=$(_rtk_summary 2>/dev/null || true)
  if [ -n "${rtk_summary:-}" ]; then
    echo "  $rtk_summary"
  fi
  echo ""

  # Log structured completion line for weekly health report aggregation
  local phase1_saved="0"
  local phase3_saved="0"
  if command -v rtk &>/dev/null; then
    phase1_saved=$(_rtk_phase_delta "phase1_start" "phase1_end" 2>/dev/null || echo "0")
    phase3_saved=$(_rtk_phase_delta "phase1_end" "phase3_end" 2>/dev/null || echo "0")
  fi
  # Log regardless of rtk — fix_iterations is useful on its own.
  # Phase durations are already in [timing] END lines; Claude parses those directly.
  _diag "WORKFLOW_COMPLETE issue=${issue_number} fix_iterations=${CURRENT_RETRY:-0} phase1_saved=${phase1_saved} phase3_saved=${phase3_saved}"

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

# ---------------------------------------------------------------------------
# handle_closed_issue ISSUE_NUMBER ISSUE_DATA
#
# Canonical handler for closed issues. Prints a full closure summary (title,
# closed date, PR number/state, branch existence) and removes any dangling
# artifacts left by a previous interrupted run:
#   1. Orphan worktree for the issue's branch
#   2. Local branch
#   3. Remote branch
#   4. Session state file
#
# Called by run_workflow() when the issue state is CLOSED. Extracted as a
# named helper so batch-process-issues.sh can delegate to it via
# workflow-runner.sh rather than duplicating or short-circuiting the logic.
#
# Parity contract: batch mode and single-issue mode must produce identical
# per-issue side effects for closed issues. Any caller that short-circuits
# before reaching this function violates the contract. See:
#   docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity"
#   tests/regression/batch-single-issue-parity.bats
#
# Returns: 12 — sentinel meaning "issue was already closed at start, no new
#   work was done in this session". batch-process-issues.sh uses this to skip
#   the post-issue stat-gathering calls (gh pr list, gh pr view, gh issue list)
#   that are only meaningful after an active dev session.
#   See: docs/architecture/exit-codes.md — exit code 12
#   See: tests/regression/batch-closed-issue-skip-stats.bats
# ---------------------------------------------------------------------------
handle_closed_issue() {
  local issue_number="$1"
  local issue_data="$2"

  local issue_title=$(echo "$issue_data" | jq -r '.title')
  local closed_at=$(echo "$issue_data" | jq -r '.closedAt')

  # Find the PR that closed this issue
  local pr_number=$(echo "$issue_data" | jq -r '.closedByPullRequestsReferences[0].number // empty' | head -1 || true)
  local pr_state=""
  local pr_merged=""
  local pr_summary=""
  local pr_branch=""
  local pr_data=""

  if [ -n "$pr_number" ]; then
    pr_data=$(gh_safe pr view "$pr_number" --json state,mergedAt,body,headRefName)
    pr_state=$(echo "$pr_data" | jq -r '.state')
    pr_merged=$(echo "$pr_data" | jq -r '.mergedAt')
    pr_summary=$(echo "$pr_data" | jq -r '.body' | head -5 || true)
    pr_branch=$(echo "$pr_data" | jq -r '.headRefName')
  fi

  # Fallback: issue was manually closed (no closedByPullRequestsReferences).
  # Search closed PRs for "Closes #N" to find the branch for artifact cleanup.
  if [ -z "$pr_branch" ]; then
    local closed_pr_number
    # sort_by(.number) | last picks the most recently created closed PR
    # deterministically when multiple closed PRs reference the same issue.
    closed_pr_number=$(gh_safe pr list --state closed --json number,body --limit 50 | \
      jq --arg issue "$issue_number" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
      '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)
    if [ -n "$closed_pr_number" ]; then
      pr_branch=$(gh_safe pr view "$closed_pr_number" --json headRefName --jq '.headRefName')
      [ -z "$pr_number" ] && pr_number="$closed_pr_number"
    fi
  fi

  # Calculate time since closed (portable date parsing)
  local closed_timestamp
  closed_timestamp=$(iso_to_epoch "$closed_at")

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

    # Show changes summary from PR body (single source of truth)
    local _pr_body_text=$(echo "$pr_data" | jq -r '.body // ""')
    local _summary
    _summary=$(extract_changes_summary "$_pr_body_text" 2>/dev/null) || _summary=""

    if [ -n "$_summary" ]; then
      echo ""
      echo "$_summary" | grep -v "^## Changes" | grep -v "^### Commits" | sed 's/^/  /'
    else
      # Fallback for PRs created before the marked-section change
      local _changed_files
      _changed_files=$(gh_safe pr view "$pr_number" --json files --jq '.files[].path')
      local _file_count=$(echo "$_changed_files" | grep -c '.' || true)
      local _commit_count
      _commit_count=$(gh_safe pr view "$pr_number" --json commits --jq '.commits | length')
      _commit_count="${_commit_count:-?}"

      echo ""
      echo "Changes: $_file_count file(s), $_commit_count commit(s)"
      if [ "$_file_count" -gt 0 ] && [ -n "$_changed_files" ]; then
        if [ "$_file_count" -le 10 ]; then
          echo "$_changed_files" | sed 's/^/  • /'
        else
          echo "$_changed_files" | head -8 | sed 's/^/  • /'
          echo "  ... and $((_file_count - 8)) more"
        fi
      fi
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Nothing to do - issue already complete! 🎉"
  echo ""

  # =========================================================================
  # CLEANUP DANGLING ARTIFACTS
  # =========================================================================
  # If a previous run crashed mid-merge or was interrupted, artifacts
  # (worktrees, branches, session state) may still exist. Clean them up.

  if [ -n "$pr_branch" ]; then
    local cleaned_anything=false
    # Tracks whether local steps 1–2 actually removed something. Used as the primary
    # gate signal for the network call in step 3: if nothing was found locally, any
    # surviving remote orphan is cosmetic (merge-pr.sh's periodic deep-clean catches
    # survivors). Skipping the network call avoids 0.3s–30s+ latency and prevents
    # TCP-reset kills (live failure: issue #201, 2026-06-04).
    # Principle: "cleanup is lazy about network state" — local first, escalate to
    # network only when local found work to do.
    # See docs/architecture/behavioral-design.md — "Cleanup operations are lazy about network state".
    local found_local_orphans=false

    # 1. Remove worktree if it exists for this branch
    # Worktrees are isolated — removing one doesn't affect others, so no need
    # to check sibling worktree status. Safe to remove even during batch runs.
    local wt_path=$(git worktree list | grep "\[$pr_branch\]" | awk '{print $1}' || true)
    if [ -n "$wt_path" ]; then
      if git worktree remove "$wt_path" --force 2>/dev/null; then
        [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
        found_local_orphans=true
        echo -e "${GREEN}  ✓ Removed worktree: $(basename "$wt_path")${NC}"
      fi
    fi

    # 2. Delete local branch if it still exists
    if git show-ref --verify --quiet "refs/heads/$pr_branch" 2>/dev/null; then
      if git branch -D "$pr_branch" >/dev/null 2>&1; then
        [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
        found_local_orphans=true
        echo -e "${GREEN}  ✓ Deleted local branch: $pr_branch${NC}"
      fi
    fi

    # 3. Delete remote branch if it still exists.
    #    Gating — two complementary signals; network is skipped only when BOTH are false:
    #
    #    Signal A — found_local_orphans (primary): steps 1–2 found something locally.
    #    When false, any remote orphan has no functional impact — the periodic deep-clean
    #    sweep in merge-pr.sh catches survivors. This is the stronger signal because it
    #    fires for ALL PR states (merged or not) based solely on observed local state.
    #    Architectural principle: "cleanup is lazy about network state".
    #    See docs/architecture/behavioral-design.md — "Cleanup operations are lazy about network state".
    #
    #    Signal B — pr_state != MERGED (defensive secondary): merge-pr.sh's
    #    `gh pr merge --delete-branch` already deleted the remote branch for merged PRs,
    #    making any ls-remote a confirmed no-op. Kept as a second line of defense and for
    #    backward compatibility with the contract from #287.
    #    See docs/architecture/behavioral-design.md — "Network Calls During Closed-Issue Cleanup".
    #
    #    Escalate to network only when found_local_orphans=true OR pr_state != MERGED.
    #    Both false = nothing local to clean + already merged = safe to skip entirely.
    #
    #    Layer 2 — timeout: network calls are wrapped with run_with_timeout 5 so a
    #    slow/hung network can't stall the workflow. Failure is non-fatal (orphan remote
    #    branches are cosmetic — cleanup continues to step 4).
    if [ "$found_local_orphans" = "true" ] || [ "${pr_state:-}" != "MERGED" ]; then
      # Layer 3 — use local remote-tracking ref when a session-level `git fetch --prune`
      # has already run (batch mode sets _BATCH_FETCH_PRUNE_DONE=true). Local check is
      # instant; network check (git ls-remote) is the fallback for single-issue mode.
      local _remote_branch_exists=false
      if [ "${_BATCH_FETCH_PRUNE_DONE:-false}" = "true" ]; then
        # Local ref check — no network round-trip
        if git show-ref --verify --quiet "refs/remotes/origin/$pr_branch" 2>/dev/null; then
          _remote_branch_exists=true
        fi
      else
        # Network check — single-issue mode or batch fetch failed; timeout prevents hangs
        if run_with_timeout 5 git ls-remote --heads origin "$pr_branch" 2>/dev/null | grep -q "$pr_branch"; then
          _remote_branch_exists=true
        fi
      fi
      if [ "$_remote_branch_exists" = "true" ]; then
        if run_with_timeout 5 git push origin --delete "$pr_branch" 2>/dev/null; then
          [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
          echo -e "${GREEN}  ✓ Deleted remote branch: origin/$pr_branch${NC}"
        else
          print_warning "Could not delete remote branch origin/$pr_branch (non-fatal, orphan branch is cosmetic)"
        fi
      fi
    fi

    # 4. Remove session state file for this issue
    local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/session-state-${issue_number}.json"
    if [ -f "$state_file" ]; then
      rm -f "$state_file"
      [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
      print_success "Removed session state: session-state-${issue_number}.json"
    fi

    if [ "$cleaned_anything" = true ]; then
      echo ""
    fi
  fi

  # Sentinel exit code 12: "issue was already closed at start, no new work done."
  # batch-process-issues.sh recognizes this and skips post-issue stat gathering
  # (gh pr list / gh pr view / gh issue list) which only make sense after an
  # active dev session. Single-issue mode treats 12 the same as 0 — not an error.
  # See: docs/architecture/exit-codes.md
  return 12
}

run_workflow() {
  local issue_number="$1"

  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}🤖 Automated Workflow Runner${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  echo "🚀 Processing issue #${issue_number} (full lifecycle)"
  echo -e "${GREEN}Session initialized (mode: $WORKFLOW_MODE)${NC}"
  echo ""

  # Check if issue is already closed — delegate to the shared helper so both
  # single-issue and batch paths execute identical cleanup side effects.
  # See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences)
  local issue_state=$(echo "$issue_data" | jq -r '.state')

  if [ "$issue_state" = "CLOSED" ]; then
    # set +e is required: handle_closed_issue returns 12 (sentinel) and under
    # set -euo pipefail a non-zero return from a bare function call aborts the
    # script immediately, making the BATCH_MODE gate below unreachable dead code.
    # Mirror the stale-branch pattern at lines 1814-1817.
    local _closed_exit
    set +e
    handle_closed_issue "$issue_number" "$issue_data"
    _closed_exit=$?
    set -e
    # Propagate the sentinel (exit 12 = closed at start, no new work).
    # batch-process-issues.sh captures this to skip post-issue stat gathering.
    # Single-issue mode: bin/rite uses exec, so exit 12 would propagate to the
    # caller's shell as a non-zero status — not an error, but surprising for
    # set -e chains and nightly automation. Gate on BATCH_MODE so single-issue
    # mode exits 0 (the closure summary was already printed by handle_closed_issue).
    if [ "${BATCH_MODE:-false}" = "true" ]; then
      return $_closed_exit
    else
      return 0
    fi
  fi

  # Ensure normalization variables are set.
  # bin/rite exports these before exec'ing workflow-runner.sh, but on direct invocation
  # or edge cases they may be missing. Fetch and normalize silently (skip approval on resume).
  if [ -z "${NORMALIZED_SUBJECT:-}" ]; then
    local _issue_json
    _issue_json=$(gh_safe issue view "$issue_number" --json title,body)
    if [ -n "$_issue_json" ] && [ "$_issue_json" != "null" ]; then
      ISSUE_DESC=$(echo "$_issue_json" | jq -r '.title // ""')
      ISSUE_BODY=$(echo "$_issue_json" | jq -r '.body // ""')
      normalize_existing_issue
      export NORMALIZED_SUBJECT WORK_DESCRIPTION ISSUE_BODY
    fi
  fi

  # Determine starting phase by inspecting actual PR state.
  # This runs every time (not just RESUME_MODE) so re-running always picks up
  # where the last run left off, with a consolidated resume summary.
  # Phase order: pre-start -> claude-workflow -> create-pr -> assess-resolve -> merge
  local skip_to_phase=""

  # ── Detect existing PR for this issue (if not already known from session state) ──
  if [ -z "${PR_NUMBER:-}" ] || [ "${PR_NUMBER:-}" = "null" ]; then
    # Method 1: Search by issue link in PR body
    # sort_by(.number) | last picks the highest-numbered (most recent) open PR
    # deterministically when multiple PRs reference the same issue.
    local _detected_pr
    _detected_pr=$(gh_safe pr list --state open --json number,body --limit 100 | \
      jq --arg issue "$issue_number" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)

    # Method 2: Detect from worktree branch (session state may have worktree but no PR)
    if { [ -z "$_detected_pr" ] || [ "$_detected_pr" = "null" ]; } && [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
      local _branch=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      if [ -n "$_branch" ]; then
        _detected_pr=$(gh_safe pr list --head "$_branch" --json number --jq '.[0].number')
      fi
    fi

    if [ -n "$_detected_pr" ] && [ "$_detected_pr" != "null" ]; then
      PR_NUMBER="$_detected_pr"
      CURRENT_PR="$PR_NUMBER"
      export PR_NUMBER
    fi
  fi

  # ── Detect worktree for this PR's branch (if not already known) ──
  if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ]; then
    if [ -z "${WORKTREE_PATH:-}" ] || [ ! -d "${WORKTREE_PATH:-}" ]; then
      local _pr_branch
      _pr_branch=$(gh_safe pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
      if [ -n "$_pr_branch" ]; then
        local _wt_path=$(git worktree list | grep "\[$_pr_branch\]" | awk '{print $1}' || true)
        if [ -n "$_wt_path" ] && [ -d "$_wt_path" ]; then
          local _file_changes=$(git -C "$_wt_path" diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')
          if [ "$_file_changes" -gt 0 ]; then
            WORKTREE_PATH="$_wt_path"
            set_current_worktree "$WORKTREE_PATH"
            RESUME_MODE=true
          fi
        fi
      fi
    fi
  fi

  # ── Stale branch check (before inspecting PR state — avoid wasted API calls on stale PRs) ──
  if [ -n "${PR_NUMBER:-}" ] && [ "$PR_NUMBER" != "null" ] && [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    source "$RITE_LIB_DIR/utils/stale-branch.sh"

    local stale_result=0
    set +e
    check_stale_branch "$WORKTREE_PATH" "$PR_NUMBER" "$issue_number" "$WORKFLOW_MODE"
    stale_result=$?
    set -e

    if [ $stale_result -eq 11 ]; then
      # Exit 11: stale-branch restarted fresh — clear all resume state so the
      # workflow falls through to phase 1 with a clean slate.
      # (Distinct from exit 10 = batch-level blocker-detected. See docs/architecture/exit-codes.md)
      PR_NUMBER=""
      CURRENT_PR=""
      WORKTREE_PATH=""
      RESUME_MODE=false
      skip_to_phase=""
      unset PR_NUMBER 2>/dev/null || true
      export -n PR_NUMBER 2>/dev/null || true
      print_info "Workflow will start fresh on issue #$issue_number"
    elif [ $stale_result -eq 2 ]; then
      # Exit 2: foreign commits detected after push rejection during stale-branch merge.
      # The branch was rebased + pushed, but a concurrent push landed foreign commits.
      # Those commits were classified as non-trivial and need a code review before merging.
      # Re-enter Phase 2→3 so the review cycle covers the combined change set.
      print_info "Foreign commits require re-review — re-entering Phase 2→3"
      skip_to_phase="create-pr"
    elif [ $stale_result -eq 5 ]; then
      # Usage cap hit during conflict resolution — propagate so batch can abort cleanly
      return 5
    elif [ $stale_result -eq 1 ]; then
      return 1
    fi
    # 0 = branch current or merged main, continue normally
  fi

  # ── Update branch against main for worktree-without-PR resume (e.g., dev-phase test failures) ──
  # The stale branch check above requires PR_NUMBER and is skipped when development never
  # created a PR (e.g., tests failed before push). Update here so the retry gets a fresh baseline.
  if [ "$RESUME_MODE" = true ] && [ -z "${PR_NUMBER:-}" ] && [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    git -C "$WORKTREE_PATH" fetch origin main 2>/dev/null || true
    local _behind_main
    _behind_main=$(git -C "$WORKTREE_PATH" rev-list --count "HEAD..origin/main" 2>/dev/null || echo "0")
    if [ "${_behind_main:-0}" -gt 0 ]; then
      print_status "Branch is $_behind_main commit(s) behind main — updating before retry..."
      local _dev_branch
      _dev_branch=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      if git -C "$WORKTREE_PATH" merge origin/main --no-edit 2>/dev/null; then
        [ -n "$_dev_branch" ] && git -C "$WORKTREE_PATH" push origin "$_dev_branch" 2>/dev/null || true
        print_success "Branch updated against main"
      else
        git -C "$WORKTREE_PATH" merge --abort 2>/dev/null || true
        print_warning "Could not auto-update branch against main — resuming anyway"
      fi
    fi
  fi

  # ── Inspect PR state to skip completed phases ──
  if [ -n "${PR_NUMBER:-}" ] && [ "$PR_NUMBER" != "null" ] && [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    print_status "Inspecting issue #$issue_number state..."

    # Get latest work commit time from LOCAL git (avoids GitHub API eventual consistency).
    # Mainline sync merge commits are filtered out (don't change PR's work scope).
    get_latest_work_commit_time "$WORKTREE_PATH" "$PR_NUMBER"
    local pr_latest_commit="$LATEST_COMMIT_TIME"

    # Get review/assessment/followup state from API (comments are immediately consistent)
    local pr_state_json _jq_pr_state
    _jq_pr_state="{latest_review: ([.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].createdAt // \"\"), latest_assessment: ([.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].body // \"\"), has_followup: ([.comments[] | select(.body | contains(\"${RITE_MARKER_FOLLOWUP}:\"))] | length > 0)}"
    pr_state_json=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_jq_pr_state")
    pr_state_json="${pr_state_json:-"{}"}"
    local pr_latest_review=$(echo "$pr_state_json" | jq -r '.latest_review // ""' 2>/dev/null)
    local pr_latest_assessment=$(echo "$pr_state_json" | jq -r '.latest_assessment // ""' 2>/dev/null)
    local pr_has_followup=$(echo "$pr_state_json" | jq -r '.has_followup // false' 2>/dev/null)

    # Determine state: review current? assessment exists? assessment approves?
    # First check for unpushed local commits — if local HEAD differs from
    # remote, the review can't be current (it doesn't cover unpushed work).
    local review_is_current=false
    local _local_head=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")
    local _pr_branch_name=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    local _remote_head=$(git -C "$WORKTREE_PATH" rev-parse "origin/$_pr_branch_name" 2>/dev/null || echo "")

    if [ "$_local_head" != "$_remote_head" ]; then
      # Unpushed commits exist — review is definitely stale
      print_info "Unpushed local commits detected — review needs refresh"
    elif [ -n "$pr_latest_review" ] && [ -n "$pr_latest_commit" ]; then
      # Compare as epoch seconds (not lexicographic) for reliable cross-format comparison
      local _rev_epoch _com_epoch
      _rev_epoch=$(iso_to_epoch "$pr_latest_review")
      _com_epoch=$(iso_to_epoch "$pr_latest_commit")
      if [ "$_rev_epoch" -gt 0 ] && [ "$_com_epoch" -gt 0 ] && [ "$_rev_epoch" -gt "$_com_epoch" ]; then
        review_is_current=true
      fi
    fi

    if [ "$review_is_current" = true ] && [ -n "$pr_latest_assessment" ]; then
      # Assessment exists — does it approve?
      local actionable_now=$(echo "$pr_latest_assessment" | grep -c "^### .* - ACTIONABLE_NOW" || true)
      local actionable_later=$(echo "$pr_latest_assessment" | grep -c "^### .* - ACTIONABLE_LATER" || true)

      if [ "$actionable_now" -eq 0 ]; then
        # Check: if ACTIONABLE_LATER items exist, tech-debt issues must be created first
        if [ "$actionable_later" -gt 0 ] && [ "$pr_has_followup" != "true" ]; then
          skip_to_phase="assess-resolve"
          print_info "Assessment passes but $actionable_later ACTIONABLE_LATER items need tech-debt issues"
        else
          skip_to_phase="merge"
          print_info "Review current, assessment passes → skipping to merge"
        fi
      else
        skip_to_phase="assess-resolve"
        print_info "Assessment has $actionable_now ACTIONABLE_NOW items → entering fix loop"
      fi
    elif [ "$review_is_current" = true ]; then
      skip_to_phase="assess-resolve"
      print_info "Review current, no assessment → running assessment"
    else
      # Review stale or missing — skip dev if work exists, run from push/review
      local _dev_changes=$(git -C "$WORKTREE_PATH" diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ')
      if [ "${_dev_changes:-0}" -gt 0 ]; then
        skip_to_phase="create-pr"
        print_info "Dev complete, review needs refresh → running from push/review"
      else
        print_info "No implementation yet → running from development"
      fi
    fi
  fi

  # Show skip summary when phases are being skipped
  if [ -n "$skip_to_phase" ]; then
    print_header "Resume Summary"
    if [ "$skip_to_phase" = "merge" ]; then
      print_success "Phase 1: Development — complete"
      print_success "Phase 2: Push & PR — open (PR #${PR_NUMBER})"
      print_success "Phase 3: Review & Assessment — all items resolved"
    elif [ "$skip_to_phase" = "assess-resolve" ]; then
      print_success "Phase 1: Development — complete"
      print_success "Phase 2: Push & PR — open (PR #${PR_NUMBER})"
    elif [ "$skip_to_phase" = "create-pr" ]; then
      print_success "Phase 1: Development — complete"
    fi
  fi

  # Phase 0: Pre-start checks.
  # Always run when not skipping at all.
  # Also force-run when resuming from a saved blocker that requires re-validation:
  # skip_to_phase reflects PR/review state, NOT whether the original blocker has
  # been resolved, so we must re-check before proceeding.
  # Reasons that trigger a pre-start re-entry (subset of persisted blocker reasons):
  #   credentials_expired — AWS creds invalid at pre-merge; blocker-rules.sh re-validates on
  #                         pre-start context (the only reason that performs real re-validation)
  #   test_failures       — test suite failed; pre-start re-entry is intentionally a no-op at
  #                         this context (test re-execution happens in the dev/fix phase itself)
  #   session_limit       — token/time limit reached; pre-start re-entry is intentionally a
  #                         no-op at this context (no environment check is performed here)
  # Excluded reasons (no pre-start re-entry needed):
  #   critical_issues     — the pre-merge gate in merge-pr.sh already re-validates review
  #                         findings before merging; a pre-start re-entry would be redundant
  # (interrupted is set by the INT/TERM trap and does NOT require a pre-start re-entry)
  local _force_prestart=false
  case "${RESUME_BLOCKER_REASON:-}" in
    credentials_expired|test_failures|session_limit)
      _force_prestart=true
      ;;
  esac

  if [ -z "$skip_to_phase" ] || [ "$_force_prestart" = true ]; then
    CURRENT_PHASE="pre-start"
    if ! phase_pre_start_checks "$issue_number"; then
      return 1
    fi
  fi

  # Phase 1: Claude workflow (development)
  if [ -z "$skip_to_phase" ] || [ "$skip_to_phase" = "claude-workflow" ]; then
    CURRENT_PHASE="claude-workflow"
    skip_to_phase=""  # Clear skip flag after reaching target
    _rtk_snapshot "phase1_start"
    _timer_start "phase1_development"
    if ! phase_claude_workflow "$issue_number"; then
      _timer_end "phase1_development"
      _rtk_snapshot "phase1_end"
      _diag "PHASE_FAILED issue=${issue_number} phase=claude-workflow"
      print_error "Workflow phase failed"
      return 1
    fi
    _timer_end "phase1_development"
    _rtk_snapshot "phase1_end"
  fi

  # Phase 2: Push work and wait for review
  if [ -z "$skip_to_phase" ] || [ "$skip_to_phase" = "create-pr" ]; then
    CURRENT_PHASE="create-pr"
    skip_to_phase=""
    _timer_start "phase2_push_review"
    phase_create_pr "$issue_number" || {
      local _create_pr_rc=$?
      _timer_end "phase2_push_review"
      _diag "PHASE_FAILED issue=${issue_number} phase=create-pr"
      if [ $_create_pr_rc -eq 5 ]; then
        print_warning "Usage cap reached during PR phase — aborting batch"
        return 5
      fi
      print_error "PR phase failed"
      return 1
    }
    _timer_end "phase2_push_review"
  fi

  # Phase 3: Assess review and resolve issues (auto-fix loop)
  if [ -z "$skip_to_phase" ] || [ "$skip_to_phase" = "assess-resolve" ]; then
    CURRENT_PHASE="assess-resolve"
    CURRENT_PR="$PR_NUMBER"
    skip_to_phase=""
    _timer_start "phase3_assess_resolve"
    # Pass RESUME_RETRY if resuming mid-loop (ensures follow-up creation happens)
    local start_retry="${RESUME_RETRY:-0}"
    if ! phase_assess_and_resolve "$issue_number" "$PR_NUMBER" "$start_retry"; then
      _timer_end "phase3_assess_resolve"
      _rtk_snapshot "phase3_end"
      _diag "PHASE_FAILED issue=${issue_number} phase=assess-resolve"
      print_error "Assessment phase failed"
      echo ""
      echo "The workflow stopped during Phase 3 (Assess & Resolve)."
      echo "Check the output above for specific error details."
      echo ""
      return 1
    fi
    _timer_end "phase3_assess_resolve"
    _rtk_snapshot "phase3_end"
  fi

  # Phase 4: Merge PR and update docs
  if [ -z "$skip_to_phase" ] || [ "$skip_to_phase" = "merge" ]; then
    CURRENT_PHASE="merge"
    skip_to_phase=""
    _timer_start "phase4_merge"
    phase_merge_pr "$issue_number" "$PR_NUMBER"
    merge_exit=$?
    if [ $merge_exit -eq 6 ]; then
      # Merge succeeded but cleanup failed — propagate exit 6
      _timer_end "phase4_merge"
      _diag "CLEANUP_FAILED issue=${issue_number} merge_succeeded=true"
      print_warning "Merge succeeded but cleanup failed"
      return 6
    elif [ $merge_exit -eq 5 ]; then
      # Usage cap reached during merge — propagate so batch aborts cleanly
      _timer_end "phase4_merge"
      _diag "PHASE_FAILED issue=${issue_number} phase=merge reason=usage_cap"
      print_warning "Usage cap reached during merge phase — aborting batch"
      return 5
    elif [ $merge_exit -ne 0 ]; then
      # Merge actually failed
      _timer_end "phase4_merge"
      _diag "PHASE_FAILED issue=${issue_number} phase=merge"
      print_error "Merge phase failed"
      return 1
    fi
    _timer_end "phase4_merge"
  fi

  # Phase 5: Completion and notifications
  CURRENT_PHASE="completion"
  phase_completion "$issue_number" "$PR_NUMBER"

  # Clear state file on successful completion
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    print_info "Cleared session state (workflow complete)"
  fi

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
    echo "  RITE_NOTIFICATIONS      Enable notifications: true/false (default: false)"
    echo "  SLACK_WEBHOOK           Slack webhook URL (requires RITE_NOTIFICATIONS=true)"
    echo "  EMAIL_NOTIFICATION_ADDRESS   Email for notifications"
    echo "  RITE_SNS_TOPIC_ARN    AWS SNS topic for SMS notifications"
    echo "  RITE_AWS_PROFILE      AWS profile for credentials (default: default)"
    echo ""
    exit 1
  fi

  local issue_number="$1"
  shift

  # Validate issue number is a positive integer (text descriptions should be resolved by bin/rite)
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [ "$issue_number" -le 0 ] 2>/dev/null; then
    print_error "Invalid issue number: $issue_number (must be positive integer)"
    print_info "Hint: rite accepts text descriptions — they get auto-created as GitHub issues"
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

  # Set up interrupt handlers for graceful Ctrl-C exit
  setup_interrupt_handlers

  # Track current issue globally for interrupt handler
  CURRENT_ISSUE="$issue_number"

  # Check for saved session state from a previous interrupt or blocker
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/session-state-${issue_number}.json"
  local RESUME_PHASE=""
  local RESUME_RETRY=0
  local saved_reason=""  # Populated from state file; exported as RESUME_BLOCKER_REASON
  if [ -f "$state_file" ]; then
    saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)
    local saved_worktree=$(jq -r '.worktree_path // ""' "$state_file" 2>/dev/null)
    local saved_phase=$(jq -r '.phase // ""' "$state_file" 2>/dev/null)
    local saved_pr=$(jq -r '.pr_number // ""' "$state_file" 2>/dev/null)
    local saved_retry=$(jq -r '.retry_count // 0' "$state_file" 2>/dev/null)

    print_info "Found saved session state (reason: $saved_reason, phase: ${saved_phase:-unknown})"

    # Use saved worktree path if it still exists
    if [ -n "$saved_worktree" ] && [ "$saved_worktree" != "null" ] && [ -d "$saved_worktree" ]; then
      WORKTREE_PATH="$saved_worktree"
      export WORKTREE_PATH
      RESUME_MODE=true
      RESUME_PHASE="$saved_phase"

      # Restore retry count if resuming to assess-resolve phase
      if [ "$saved_phase" = "assess-resolve" ] && [ -n "$saved_retry" ] && [ "$saved_retry" != "null" ]; then
        RESUME_RETRY="$saved_retry"
        CURRENT_RETRY="$saved_retry"
      fi

      # Restore PR number if available
      if [ -n "$saved_pr" ] && [ "$saved_pr" != "null" ]; then
        CURRENT_PR="$saved_pr"
        PR_NUMBER="$saved_pr"
        export PR_NUMBER
      fi

      print_success "Resuming from phase: ${saved_phase:-unknown}"
      print_status "Worktree: $WORKTREE_PATH"
      [ -n "$CURRENT_PR" ] && print_status "PR: #$CURRENT_PR"
      [ "$RESUME_RETRY" -gt 0 ] && print_status "Retry: $RESUME_RETRY/3"
    else
      print_warning "Saved worktree no longer exists - starting fresh"
      saved_reason=""
    fi
  fi

  # Export resume phase, retry, and blocker reason for run_workflow
  export RESUME_PHASE
  export RESUME_RETRY
  # RESUME_BLOCKER_REASON carries the saved blocker type so run_workflow can
  # force pre-start checks even when skip_to_phase would normally bypass them.
  export RESUME_BLOCKER_REASON="${saved_reason:-}"

  # Initialize session — but not when called from batch mode (batch owns the session).
  # Set RITE_RESUMING=true when we're picking up from a saved worktree so that
  # init_session preserves the existing start_time and cumulative_work_seconds
  # rather than resetting the clock (issue #283 — Option 2 fix).
  if [ "${BATCH_MODE:-false}" != "true" ]; then
    if [ "$RESUME_MODE" = true ]; then
      export RITE_RESUMING=true
    else
      export RITE_RESUMING=false
    fi
    init_session "$WORKFLOW_MODE"
  fi

  # Restore worktree path from saved state if resuming
  if [ "$RESUME_MODE" = true ] && [ -n "$WORKTREE_PATH" ]; then
    set_current_worktree "$WORKTREE_PATH"
  fi

  # Start per-issue duration tracking for single-issue path (issue #283 — Option 1).
  # In batch mode, batch-process-issues.sh handles this around the workflow-runner call.
  if [ "${BATCH_MODE:-false}" != "true" ]; then
    start_issue_tracking "$issue_number"
  fi

  # Run the workflow
  run_workflow "$issue_number"
  workflow_exit=$?

  # End per-issue duration tracking before exit (single-issue path)
  if [ "${BATCH_MODE:-false}" != "true" ]; then
    end_issue_tracking "$issue_number"
  fi

  if [ $workflow_exit -eq 0 ]; then
    exit 0
  elif [ $workflow_exit -eq 12 ]; then
    # Issue was already closed at start — sentinel for batch stat-gathering skip.
    # Not an error: the closure summary was already printed by handle_closed_issue().
    # Only reachable when BATCH_MODE=true (run_workflow returns 0 in single-issue mode
    # so callers in set -e chains and nightly automation see a clean exit).
    # batch-process-issues.sh captures this exit code and routes to the
    # already_closed_at_start path, skipping the post-issue gh API calls.
    # See: docs/architecture/exit-codes.md
    exit 12
  elif [ $workflow_exit -eq 6 ]; then
    # Merge succeeded but cleanup failed — propagate exit 6 to batch reporter
    exit 6
  elif [ $workflow_exit -eq 5 ]; then
    # Usage cap reached — propagate exit 5 so batch can abort cleanly
    exit 5
  else
    print_error "Workflow failed"
    exit 1
  fi
}

# Run main if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
