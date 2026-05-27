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
source "$RITE_LIB_DIR/utils/pr-summary.sh"
source "$RITE_LIB_DIR/utils/normalize-issue.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
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

  # Check session limits
  local issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local elapsed_hours=$(get_elapsed_hours)

  if ! check_blockers "session-check" "$issues_completed" "$elapsed_hours"; then
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

              if git stash push -u -m "$STASH_MSG" 2>/dev/null; then
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
                _pr_adds=$(gh pr view "$pr_number" --json additions --jq '.additions' 2>/dev/null || echo "0")
                if [ "${_pr_adds:-0}" -eq 0 ]; then
                  gh pr close "$pr_number" --delete-branch 2>/dev/null || true
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
          WORKTREE_PATH=$(git worktree list | awk '{print $1}' | grep -v "^${_main_wt}$" | grep -E "(issue.?${issue_number}|#${issue_number})" | head -1)
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

      # ── Pre-dev verification: check if issue is already resolved on main ──
      # If the issue has runnable verification commands and they all pass on main,
      # skip the dev session entirely. This prevents wasted sessions where Claude
      # determines "no changes needed" and produces empty PRs (exit code 4).
      if [ -n "${ISSUE_BODY:-}" ]; then
        local _verify_block=""
        _verify_block=$(echo "$ISSUE_BODY" | sed -n '/^## Verification Commands/,/^## /p' | sed '1d;/^## /d')

        # Extract commands from fenced code block (```bash ... ```)
        local _verify_cmds=""
        if [ -n "$_verify_block" ]; then
          _verify_cmds=$(echo "$_verify_block" | sed -n '/^```/,/^```/p' | grep -v '^```' | grep -v '^\s*$' || true)
        fi

        if [ -n "$_verify_cmds" ]; then
          print_status "Pre-dev check: running verification commands against main..."
          local _all_passed=true
          local _cmd_count=0
          local _pass_count=0

          # Allowlist for safe command execution (no eval)
          # Security model: Issue bodies are attacker-controlled (anyone with Issues: Write
          # can inject commands). We use strict allowlisting instead of eval to prevent RCE.
          # Only specific test runners are permitted, and all arguments must match safe patterns.
          local -a _allowed_commands=( pytest npm make python python3 cargo go bats jest vitest )
          local -a _allowed_subcommands=( test run check -m )

          while IFS= read -r _cmd; do
            # Skip comments and empty lines
            [[ "$_cmd" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${_cmd// /}" ]] && continue
            _cmd_count=$((_cmd_count + 1))

            # Parse command into tokens (no eval - direct token parsing)
            local -a _tokens=()
            # Use read -ra for safe tokenization on space boundaries
            IFS=' ' read -ra _tokens <<< "$_cmd"

            # Validate first token (command name) against allowlist
            local _cmd_name="${_tokens[0]:-}"
            local _cmd_allowed=false
            for _allowed_cmd in "${_allowed_commands[@]}"; do
              if [ "$_cmd_name" = "$_allowed_cmd" ]; then
                _cmd_allowed=true
                break
              fi
            done

            if [ "$_cmd_allowed" = false ]; then
              print_warning "Unrecognized verification command: $_cmd — skipping"
              _all_passed=false
              continue
            fi

            # Validate all subsequent tokens against safe patterns
            # Flags: -x, --flag, --key=value
            # Paths: ./path, path/to/file, filename.ext
            # Reject: shell metacharacters (;, &, |, $, backticks, parentheses)
            # Reject: path traversal sequences (..)
            local _tokens_valid=true
            for (( _i=1; _i<${#_tokens[@]}; _i++ )); do
              local _token="${_tokens[$_i]}"
              # Allow flags: -x or --flag or --key=value
              if [[ "$_token" =~ ^-{1,2}[a-zA-Z0-9_=.-]+$ ]]; then
                # Reject -c flag for python/python3 (enables arbitrary code execution)
                if [[ "$_cmd_name" =~ ^python3?$ ]] && [[ "$_token" = "-c" ]]; then
                  print_warning "Dangerous flag in verification command: -c not allowed with python (in: $_cmd) — skipping"
                  _tokens_valid=false
                  break
                fi
                continue
              fi
              # Allow paths: ./path, path/to/file, filename
              # But reject path traversal sequences (..)
              if [[ "$_token" =~ ^[./a-zA-Z0-9_=./-]+$ ]] && [[ ! "$_token" =~ \.\. ]]; then
                continue
              fi
              # Allow specific subcommands (test, run, check, -m)
              local _is_subcommand=false
              for _allowed_sub in "${_allowed_subcommands[@]}"; do
                if [ "$_token" = "$_allowed_sub" ]; then
                  _is_subcommand=true
                  break
                fi
              done
              if [ "$_is_subcommand" = true ]; then
                continue
              fi
              # Token doesn't match any safe pattern - reject command
              print_warning "Unsafe token in verification command: $_token (in: $_cmd) — skipping"
              _tokens_valid=false
              break
            done

            if [ "$_tokens_valid" = false ]; then
              _all_passed=false
              continue
            fi

            # Execute command directly (no eval, no bash -c)
            # This is safe because we've validated all tokens against strict patterns
            if "${_tokens[@]}" >/dev/null 2>&1; then
              _pass_count=$((_pass_count + 1))
            else
              _all_passed=false
              break
            fi
          done <<< "$_verify_cmds"

          if [ "$_all_passed" = true ] && [ "$_cmd_count" -gt 0 ]; then
            print_success "All $_cmd_count verification command(s) pass on main — issue already resolved"
            echo ""

            # Close the issue with explanation
            gh issue close "$issue_number" \
              --comment "Automatically closed by sharkrite: all verification commands in this issue already pass on main. No development needed.

**Verification results:** $_pass_count/$_cmd_count commands passed.

<!-- sharkrite-auto-resolved -->" 2>/dev/null || true

            ISSUE_ALREADY_RESOLVED=true
            return 0
          elif [ "$_cmd_count" -gt 0 ]; then
            print_info "Pre-dev check: $_pass_count/$_cmd_count verification commands pass — development needed"
          fi
        fi
      fi

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
          grep -E "(issue.?${issue_number}|#${issue_number}|[-_]${issue_number}[-_]|[-_]${issue_number}$)" | head -1)
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
            grep -E "(issue.?${issue_number}|#${issue_number}|[-_]${issue_number}[-_]|[-_]${issue_number}$)" | head -1)
        fi

        if [ $workflow_exit -eq 4 ]; then
          print_error "Development produced no changes after retry"
          print_info "Issue may need manual investigation or a clearer description"

          # Clean up empty draft PR so it doesn't cause stale worktree loops on next run
          if [ -n "${PR_NUMBER:-}" ]; then
            local _pr_additions
            _pr_additions=$(gh pr view "$PR_NUMBER" --json additions --jq '.additions' 2>/dev/null || echo "0")
            if [ "${_pr_additions:-0}" -eq 0 ]; then
              gh pr close "$PR_NUMBER" --delete-branch 2>/dev/null || true
              print_info "Closed empty draft PR #$PR_NUMBER"
            fi
          fi
          return 1
        elif [ $workflow_exit -eq 3 ]; then
          BLOCKER_TYPE=test_failures BLOCKER_DETAILS="Test suite failed during development phase — see output above"
          if ! handle_blocker "pre-merge" "$issue_number"; then
            return 1
          fi
        elif [ $workflow_exit -ne 0 ]; then
          print_error "Development workflow failed on retry (exit code: $workflow_exit)"
          return $workflow_exit
        fi
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
  PR_NUMBER=$(gh pr list --head "$branch_name" --json number --jq '.[0].number' 2>/dev/null || echo "")

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

    local latest_review_time
    latest_review_time=$(gh pr view "$PR_NUMBER" --json comments --jq '
      [.comments[] | select(
        .body | contains("<!-- sharkrite-local-review")
      )] | sort_by(.createdAt) | reverse | .[0].createdAt // ""
    ' 2>/dev/null || echo "")

    if [ -n "$latest_review_time" ] && [ -n "$latest_local_commit_time" ]; then
      # Compare as epoch seconds (not lexicographic) for reliable cross-format comparison.
      # Matches the epoch comparison in assess-and-resolve.sh (line ~500).
      local review_epoch commit_epoch
      if date --version >/dev/null 2>&1; then
        review_epoch=$(date -d "$latest_review_time" "+%s" 2>/dev/null || echo "0")
        commit_epoch=$(date -d "$latest_local_commit_time" "+%s" 2>/dev/null || echo "0")
      else
        review_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$latest_review_time" "+%s" 2>/dev/null || echo "0")
        commit_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$latest_local_commit_time" "+%s" 2>/dev/null || echo "0")
      fi
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
    local pr_assess_state=$(gh pr view "$pr_number" --json comments --jq '{
      assessment: ([.comments[] | select(.body | contains("<!-- sharkrite-assessment"))] |
        sort_by(.createdAt) | reverse | .[0].body // ""),
      has_followup: ([.comments[] | select(.body | contains("sharkrite-followup-issue:"))] | length > 0)
    }' 2>/dev/null || echo "{}")

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
  local followup_marker=$(gh pr view "$pr_number" --json comments --jq '.comments[].body' 2>/dev/null | grep -oE 'sharkrite-followup-issue:[0-9]+' | tail -1 || echo "")
  if [ -n "$followup_marker" ]; then
    local followup_issue_num=$(echo "$followup_marker" | cut -d: -f2)
    local followup_state=$(gh issue view "$followup_issue_num" --json state --jq '.state' 2>/dev/null || echo "")

    if [ "$followup_state" = "CLOSED" ]; then
      print_success "✅ Follow-up issue #$followup_issue_num has been resolved"
      print_info "Skipping assessment loop - proceeding to merge"
      return 0
    elif [ -n "$followup_state" ]; then
      print_info "📋 Follow-up issue #$followup_issue_num exists (state: $followup_state)"
      print_info "Workflow will continue assessment to check if PR is ready to merge"
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
      elif [ $fix_result -ne 0 ]; then
        print_error "Claude workflow fix mode failed (exit code: $fix_result)"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Troubleshooting:"
        echo "  1. Check the latest assessment comment on PR #$pr_number"
        echo "  2. The Claude session may have timed out or errored"
        echo "  3. Run manually to debug:"
        echo "     cd $WORKTREE_PATH"
        echo "     gh pr view $pr_number --json comments --jq '[.comments[] | select(.body | contains(\"sharkrite-assessment\"))] | .[-1].body'"
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
    local _post_reroute_review_time
    _post_reroute_review_time=$(gh pr view "$PR_NUMBER" --json comments --jq '
      [.comments[] | select(
        .body | contains("<!-- sharkrite-local-review")
      )] | sort_by(.createdAt) | reverse | .[0].createdAt // ""
    ' 2>/dev/null || echo "")

    # Ensure commit time is available (phase_create_pr may skip computing it)
    if [ -z "${LATEST_COMMIT_TIME:-}" ]; then
      get_latest_work_commit_time "$WORKTREE_PATH" "$PR_NUMBER"
    fi

    if [ -n "$_post_reroute_review_time" ] && [ -n "${LATEST_COMMIT_TIME:-}" ]; then
      local _rr_review_epoch _rr_commit_epoch
      if date --version >/dev/null 2>&1; then
        _rr_review_epoch=$(date -d "$_post_reroute_review_time" "+%s" 2>/dev/null || echo "0")
        _rr_commit_epoch=$(date -d "$LATEST_COMMIT_TIME" "+%s" 2>/dev/null || echo "0")
      else
        _rr_review_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$_post_reroute_review_time" "+%s" 2>/dev/null || echo "0")
        _rr_commit_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$LATEST_COMMIT_TIME" "+%s" 2>/dev/null || echo "0")
      fi
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
  local _pr_info=$(gh pr view "$pr_number" --json title,body 2>/dev/null || echo "{}")
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
      local _changed_files=$(gh pr view "$pr_number" --json files --jq '.files[].path' 2>/dev/null || echo "")
      local _file_count=$(echo "$_changed_files" | grep -c '.' || true)
      local _commit_count=$(gh pr view "$pr_number" --json commits --jq '.commits | length' 2>/dev/null || echo "?")
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

  if [ $merge_result -ne 0 ]; then
    print_error "Merge failed"
    return 1
  fi

  # merge-pr.sh runs inside the worktree and can't delete the branch it has checked
  # out (git refuses to delete a branch checked out in the current worktree). After
  # merge-pr.sh returns the worktree is gone, but the CWD is now a deleted directory.
  # Use -C with the main repo root so git commands resolve correctly.
  #
  # Prune stale worktree metadata first — git worktree remove sometimes leaves
  # entries in .git/worktrees/, causing branch -D to fail with "checked out at".
  git -C "$RITE_PROJECT_ROOT" worktree prune 2>/dev/null || true

  local _merged_branch
  _merged_branch=$(gh pr view "$pr_number" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
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
    local pr_branch=""

    if [ -n "$pr_number" ]; then
      local pr_data=$(gh pr view "$pr_number" --json state,mergedAt,body,headRefName 2>/dev/null)
      pr_state=$(echo "$pr_data" | jq -r '.state')
      pr_merged=$(echo "$pr_data" | jq -r '.mergedAt')
      pr_summary=$(echo "$pr_data" | jq -r '.body' | head -5)
      pr_branch=$(echo "$pr_data" | jq -r '.headRefName')
    fi

    # Fallback: issue was manually closed (no closedByPullRequestsReferences).
    # Search closed PRs for "Closes #N" to find the branch for artifact cleanup.
    if [ -z "$pr_branch" ]; then
      local closed_pr_number
      closed_pr_number=$(gh pr list --state closed --json number,body --limit 50 2>/dev/null | \
        jq --arg issue "$issue_number" -r \
        '.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .number' | \
        head -1)
      if [ -n "$closed_pr_number" ]; then
        pr_branch=$(gh pr view "$closed_pr_number" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
        [ -z "$pr_number" ] && pr_number="$closed_pr_number"
      fi
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

      # Show changes summary from PR body (single source of truth)
      local _pr_body_text=$(echo "$pr_data" | jq -r '.body // ""')
      local _summary
      _summary=$(extract_changes_summary "$_pr_body_text" 2>/dev/null) || _summary=""

      if [ -n "$_summary" ]; then
        echo ""
        echo "$_summary" | grep -v "^## Changes" | grep -v "^### Commits" | sed 's/^/  /'
      else
        # Fallback for PRs created before the marked-section change
        local _changed_files=$(gh pr view "$pr_number" --json files --jq '.files[].path' 2>/dev/null || echo "")
        local _file_count=$(echo "$_changed_files" | grep -c '.' || true)
        local _commit_count=$(gh pr view "$pr_number" --json commits --jq '.commits | length' 2>/dev/null || echo "?")

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

      # 1. Remove worktree if it exists for this branch
      # Worktrees are isolated — removing one doesn't affect others, so no need
      # to check sibling worktree status. Safe to remove even during batch runs.
      local wt_path=$(git worktree list | grep "\[$pr_branch\]" | awk '{print $1}')
      if [ -n "$wt_path" ]; then
        if git worktree remove "$wt_path" --force 2>/dev/null; then
          [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
          echo -e "${GREEN}  ✓ Removed worktree: $(basename "$wt_path")${NC}"
        fi
      fi

      # 2. Delete local branch if it still exists
      if git show-ref --verify --quiet "refs/heads/$pr_branch" 2>/dev/null; then
        if git branch -D "$pr_branch" >/dev/null 2>&1; then
          [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
          echo -e "${GREEN}  ✓ Deleted local branch: $pr_branch${NC}"
        fi
      fi

      # 3. Delete remote branch if it still exists
      if git ls-remote --heads origin "$pr_branch" 2>/dev/null | grep -q "$pr_branch"; then
        if git push origin --delete "$pr_branch" 2>/dev/null; then
          [ "$cleaned_anything" = false ] && print_status "Cleaning up artifacts..." && cleaned_anything=true
          echo -e "${GREEN}  ✓ Deleted remote branch: origin/$pr_branch${NC}"
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

    return 0
  fi

  # Ensure normalization variables are set.
  # bin/rite exports these before exec'ing workflow-runner.sh, but on direct invocation
  # or edge cases they may be missing. Fetch and normalize silently (skip approval on resume).
  if [ -z "${NORMALIZED_SUBJECT:-}" ]; then
    local _issue_json
    _issue_json=$(gh issue view "$issue_number" --json title,body 2>/dev/null || echo "")
    if [ -n "$_issue_json" ] && [ "$_issue_json" != "null" ]; then
      ISSUE_DESC=$(echo "$_issue_json" | jq -r '.title // ""')
      ISSUE_BODY=$(echo "$_issue_json" | jq -r '.body // ""')
      normalize_existing_issue
      export NORMALIZED_SUBJECT WORK_DESCRIPTION
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
    local _detected_pr=$(gh pr list --state open --json number,body --limit 100 2>/dev/null | \
      jq --arg issue "$issue_number" -r '.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .number' | \
      head -1)

    # Method 2: Detect from worktree branch (session state may have worktree but no PR)
    if { [ -z "$_detected_pr" ] || [ "$_detected_pr" = "null" ]; } && [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
      local _branch=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      if [ -n "$_branch" ]; then
        _detected_pr=$(gh pr list --head "$_branch" --json number --jq '.[0].number' 2>/dev/null || echo "")
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
      local _pr_branch=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
      if [ -n "$_pr_branch" ]; then
        local _wt_path=$(git worktree list | grep "\[$_pr_branch\]" | awk '{print $1}')
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

    if [ $stale_result -eq 10 ]; then
      # Restarted fresh — clear all resume state so workflow falls through
      PR_NUMBER=""
      CURRENT_PR=""
      WORKTREE_PATH=""
      RESUME_MODE=false
      skip_to_phase=""
      unset PR_NUMBER 2>/dev/null || true
      export -n PR_NUMBER 2>/dev/null || true
      print_info "Workflow will start fresh on issue #$issue_number"
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
    local pr_state_json=$(gh pr view "$PR_NUMBER" --json comments --jq '{
      latest_review: ([.comments[] | select(
        .body | contains("<!-- sharkrite-local-review")
      )] | sort_by(.createdAt) | reverse | .[0].createdAt // ""),
      latest_assessment: ([.comments[] | select(
        .body | contains("<!-- sharkrite-assessment")
      )] | sort_by(.createdAt) | reverse | .[0].body // ""),
      has_followup: ([.comments[] | select(
        .body | contains("sharkrite-followup-issue:")
      )] | length > 0)
    }' 2>/dev/null || echo "{}")
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
      if date --version >/dev/null 2>&1; then
        _rev_epoch=$(date -d "$pr_latest_review" "+%s" 2>/dev/null || echo "0")
        _com_epoch=$(date -d "$pr_latest_commit" "+%s" 2>/dev/null || echo "0")
      else
        _rev_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$pr_latest_review" "+%s" 2>/dev/null || echo "0")
        _com_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$pr_latest_commit" "+%s" 2>/dev/null || echo "0")
      fi
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

  # Phase 0: Pre-start checks (always run unless skipping past it)
  if [ -z "$skip_to_phase" ]; then
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
    if ! phase_create_pr "$issue_number"; then
      _timer_end "phase2_push_review"
      _diag "PHASE_FAILED issue=${issue_number} phase=create-pr"
      print_error "PR phase failed"
      return 1
    fi
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
    if ! phase_merge_pr "$issue_number" "$PR_NUMBER"; then
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
  if [ -f "$state_file" ]; then
    local saved_reason=$(jq -r '.reason // "unknown"' "$state_file" 2>/dev/null)
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
    fi
  fi

  # Export resume phase and retry for run_workflow
  export RESUME_PHASE
  export RESUME_RETRY

  # Initialize session — but not when called from batch mode (batch owns the session)
  if [ "${BATCH_MODE:-false}" != "true" ]; then
    init_session "$WORKFLOW_MODE"
  fi

  # Restore worktree path from saved state if resuming
  if [ "$RESUME_MODE" = true ] && [ -n "$WORKTREE_PATH" ]; then
    set_current_worktree "$WORKTREE_PATH"
  fi

  # Run the workflow
  if run_workflow "$issue_number"; then
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
