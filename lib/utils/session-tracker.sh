#!/bin/bash
# lib/utils/session-tracker.sh
# Track session state, time, and token usage
# Usage: source this file and call session tracking functions
#
# Expects config.sh to be already loaded (provides SESSION_STATE_FILE,
# RITE_PROJECT_NAME, RITE_WORKTREE_DIR, RITE_DATA_DIR)

# Initialize session tracking
init_session() {
  local mode="${1:-supervised}"  # supervised or unsupervised

  # Preserve cross-run state (blocker approvals, notification dedup).
  # Session counters reset, but approvals and dedup are per-issue and must survive.
  local existing_approvals="[]"
  local existing_notifications="[]"
  if [ -f "$SESSION_STATE_FILE" ]; then
    existing_approvals=$(jq -c '.approved_blockers // []' "$SESSION_STATE_FILE" 2>/dev/null || echo "[]")
    existing_notifications=$(jq -c '.sent_notifications // []' "$SESSION_STATE_FILE" 2>/dev/null || echo "[]")
  fi

  cat > "$SESSION_STATE_FILE" <<EOF
{
  "start_time": $(date +%s),
  "mode": "$mode",
  "issues_completed": 0,
  "issues_failed": 0,
  "current_issue": null,
  "worktree_path": null,
  "approved_blockers": $existing_approvals,
  "sent_notifications": $existing_notifications,
  "last_update": $(date +%s)
}
EOF

  export SESSION_START_TIME=$(date +%s)
}

# Update session state
update_session() {
  local key="$1"
  local value="$2"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  # Update JSON using jq
  local temp=$(mktemp)
  jq ".${key} = ${value} | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"
}

# Get session info
get_session_info() {
  if [ ! -f "$SESSION_STATE_FILE" ]; then
    echo "{}"
    return
  fi

  cat "$SESSION_STATE_FILE"
}

# Get elapsed time
get_elapsed_time() {
  local start_time=$(jq -r '.start_time' "$SESSION_STATE_FILE" 2>/dev/null || echo "$(date +%s)")
  local current_time=$(date +%s)
  local elapsed=$((current_time - start_time))

  echo "$elapsed"
}

# Get elapsed hours
get_elapsed_hours() {
  local elapsed=$(get_elapsed_time)
  echo $((elapsed / 3600))
}

# Format elapsed time for display
format_elapsed_time() {
  local elapsed=$(get_elapsed_time)
  local hours=$((elapsed / 3600))
  local minutes=$(( (elapsed % 3600) / 60 ))
  local seconds=$((elapsed % 60))

  if [ $hours -gt 0 ]; then
    echo "${hours}h ${minutes}m ${seconds}s"
  elif [ $minutes -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

# Increment completed issues
increment_completed() {
  local current=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  update_session "issues_completed" $((current + 1))
}

# Increment failed issues
increment_failed() {
  local current=$(jq -r '.issues_failed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  update_session "issues_failed" $((current + 1))
}

# Set current issue
set_current_issue() {
  local issue_number="$1"
  update_session "current_issue" "\"$issue_number\""
}

# Set current worktree
set_current_worktree() {
  local worktree_path="$1"
  update_session "worktree_path" "\"$worktree_path\""
}

# Check if should continue or save state
should_save_and_exit() {
  local issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local elapsed_hours=$(get_elapsed_hours)

  # Conservative limits (from blocker-rules.sh)
  if [ "$issues_completed" -ge "${RITE_MAX_ISSUES_PER_SESSION:-8}" ]; then
    echo "token_limit"
    return 0
  fi

  if [ "$elapsed_hours" -ge "${RITE_MAX_SESSION_HOURS:-4}" ]; then
    echo "time_limit"
    return 0
  fi

  echo "continue"
  return 1
}

# Save session state for resume
save_session_state() {
  local issue_number="$1"
  local reason="$2"
  local worktree_path="$3"

  local data_dir="${RITE_DATA_DIR:-.rite}"
  local state_file="${RITE_PROJECT_ROOT:-.}/${data_dir}/session-state-${issue_number}.json"

  cat > "$state_file" <<EOF
{
  "saved_at": $(date +%s),
  "saved_at_human": "$(date '+%Y-%m-%d %H:%M:%S')",
  "reason": "$reason",
  "issue_number": "$issue_number",
  "worktree_path": "$worktree_path",
  "session_info": $(cat "$SESSION_STATE_FILE"),
  "git_status": "$(cd "$worktree_path" 2>/dev/null && git status --short | base64)",
  "last_commit": "$(cd "$worktree_path" 2>/dev/null && git log -1 --oneline)"
}
EOF

  echo "💾 Session state saved to: $state_file"
}

# Create resume script
create_resume_script() {
  local issue_number="$1"
  local blocker_type="$2"
  local blocker_details="$3"
  local worktree_path="$4"
  local pr_number="${5:-}"

  local timestamp=$(date +%Y%m%d-%H%M%S)
  local data_dir="${RITE_DATA_DIR:-.rite}"
  local resume_script="${RITE_PROJECT_ROOT:-.}/${data_dir}/resume-${issue_number}-${timestamp}.sh"

  cat > "$resume_script" <<EOF
#!/bin/bash
# Auto-generated resume script
# Created: $(date '+%Y-%m-%d %H:%M:%S')
# Issue: #${issue_number}
# Blocker: ${blocker_type}

# ===================================================================
# STATE SNAPSHOT
# ===================================================================

ISSUE_NUMBER=${issue_number}
WORKTREE_PATH="${worktree_path}"
PR_NUMBER="${pr_number}"
BLOCKER_TYPE="${blocker_type}"

# ===================================================================
# BLOCKER DETAILS
# ===================================================================

cat <<'BLOCKER_EOF'
${blocker_details}
BLOCKER_EOF

echo ""
echo "=========================================="
echo "🔄 Resume Workflow for Issue #${issue_number}"
echo "=========================================="
echo ""

# Show current state
if [ -f "${data_dir}/session-state-${issue_number}.json" ]; then
  echo "📊 Saved Session State:"
  cat "${data_dir}/session-state-${issue_number}.json" | jq .
  echo ""
fi

# Show git status if worktree exists
if [ -d "\$WORKTREE_PATH" ]; then
  echo "📂 Worktree Status:"
  cd "\$WORKTREE_PATH"
  git status --short
  echo ""
  echo "📝 Last Commit:"
  git log -1 --oneline
  echo ""
else
  echo "⚠️  Worktree not found at: \$WORKTREE_PATH"
  echo ""
fi

# ===================================================================
# BLOCKER-SPECIFIC INSTRUCTIONS
# ===================================================================

case "\$BLOCKER_TYPE" in
  infrastructure|database_migration)
    echo "⚠️  Manual Review Required"
    echo ""
    echo "This blocker requires you to review and approve changes:"
    echo "1. Review the changes above"
    echo "2. Test locally if needed"
    echo "3. Confirm it's safe to proceed"
    echo ""
    ;;

  session_limit|token_limit)
    echo "ℹ️  Session Limit Reached"
    echo ""
    echo "Work was saved automatically. Ready to continue in fresh session."
    echo ""
    ;;

  credentials_expired)
    echo "🔑 AWS Credentials Expired"
    echo ""
    echo "Run: aws sso login --profile \${RITE_AWS_PROFILE:-default}"
    echo "Then continue with this script."
    echo ""
    ;;
esac

# ===================================================================
# RESUME PROMPT
# ===================================================================

read -p "Ready to continue workflow? (y/n) " -n 1 -r
echo
echo

if [[ ! \$REPLY =~ ^[Yy]$ ]]; then
  echo "❌ Cancelled."
  echo ""
  echo "To manually work on this issue:"
  echo "  cd \$WORKTREE_PATH"
  echo "  claude-code"
  exit 0
fi

# ===================================================================
# RESUME WORKFLOW
# ===================================================================

echo "✅ Resuming workflow..."
echo ""

# Navigate to worktree
cd "\$WORKTREE_PATH" || exit 1

# Re-export environment
export WORKFLOW_MODE="\${WORKFLOW_MODE:-supervised}"
export EMAIL_NOTIFICATION_ADDRESS="${EMAIL_NOTIFICATION_ADDRESS:-}"
export SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
export ISSUE_NUMBER=\$ISSUE_NUMBER

# Call rite to continue
rite \$ISSUE_NUMBER --resume

EOF

  chmod +x "$resume_script"

  echo "📄 Resume script created: $resume_script"
  echo ""
  echo "To resume later, run:"
  echo "  $resume_script"
}

# Get session summary
get_session_summary() {
  local session_info=$(get_session_info)

  local completed=$(echo "$session_info" | jq -r '.issues_completed')
  local failed=$(echo "$session_info" | jq -r '.issues_failed')
  local elapsed=$(format_elapsed_time)
  local mode=$(echo "$session_info" | jq -r '.mode')

  cat <<EOF
📊 Session Summary
==================
Mode: $mode
Duration: $elapsed
Issues Completed: $completed
Issues Failed: $failed
Total Processed: $((completed + failed))
EOF
}

# Track an approved blocker to avoid re-prompting
add_approved_blocker() {
  local issue_number="$1"
  local blocker_type="$2"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  # Add to approved_blockers array (keyed by issue:blocker_type)
  local key="${issue_number}:${blocker_type}"
  local temp=$(mktemp)
  jq ".approved_blockers = ((.approved_blockers // []) + [\"$key\"] | unique) | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"
}

# Check if a blocker was already approved for this issue
has_approved_blocker() {
  local issue_number="$1"
  local blocker_type="$2"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    return 1  # No session = not approved
  fi

  local key="${issue_number}:${blocker_type}"
  local found=$(jq -r ".approved_blockers // [] | index(\"$key\") != null" "$SESSION_STATE_FILE" 2>/dev/null)

  if [ "$found" = "true" ]; then
    return 0  # Already approved
  else
    return 1  # Not approved
  fi
}

# Track a sent notification to avoid duplicates
add_sent_notification() {
  local issue_number="$1"
  local notification_type="$2"  # e.g., "blocker:auth_changes"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  local key="${issue_number}:${notification_type}"
  local temp=$(mktemp)
  jq ".sent_notifications = ((.sent_notifications // []) + [\"$key\"] | unique) | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"
}

# Check if a notification was already sent for this issue
has_sent_notification() {
  local issue_number="$1"
  local notification_type="$2"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    return 1  # No session = not sent
  fi

  local key="${issue_number}:${notification_type}"
  local found=$(jq -r ".sent_notifications // [] | index(\"$key\") != null" "$SESSION_STATE_FILE" 2>/dev/null)

  if [ "$found" = "true" ]; then
    return 0  # Already sent
  else
    return 1  # Not sent
  fi
}

# Clean up session state
cleanup_session() {
  rm -f "$SESSION_STATE_FILE"
  echo "✅ Session cleaned up"
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f init_session
  export -f update_session
  export -f get_session_info
  export -f get_elapsed_time
  export -f get_elapsed_hours
  export -f format_elapsed_time
  export -f increment_completed
  export -f increment_failed
  export -f set_current_issue
  export -f set_current_worktree
  export -f should_save_and_exit
  export -f save_session_state
  export -f create_resume_script
  export -f get_session_summary
  export -f add_approved_blocker
  export -f has_approved_blocker
  export -f add_sent_notification
  export -f has_sent_notification
  export -f cleanup_session
fi
