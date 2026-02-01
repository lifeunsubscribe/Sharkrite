#!/bin/bash
# lib/utils/notifications.sh
# Multi-channel notification system (Slack, Email, SMS)
# Usage: source this file and call notification functions
#
# Expects config.sh to be already loaded (provides FORGE_SNS_TOPIC_ARN,
# FORGE_AWS_PROFILE, FORGE_EMAIL_FROM, FORGE_PROJECT_NAME, SLACK_WEBHOOK,
# EMAIL_NOTIFICATION_ADDRESS)

# Configuration from environment (with config.sh defaults)
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_ADDRESS="${EMAIL_NOTIFICATION_ADDRESS:-}"
SNS_TOPIC_ARN="${FORGE_SNS_TOPIC_ARN:-}"
AWS_PROFILE="${FORGE_AWS_PROFILE:-default}"

# Send Slack notification
send_slack() {
  local message="$1"
  local urgency="${2:-normal}"  # normal or urgent

  if [ -z "$SLACK_WEBHOOK" ]; then
    echo "⚠️  SLACK_WEBHOOK not set, skipping Slack notification"
    return 1
  fi

  # Add urgency indicator
  local icon=":robot_face:"
  [ "$urgency" = "urgent" ] && icon=":rotating_light:"

  local payload=$(cat <<EOF
{
  "text": "${icon} ${FORGE_PROJECT_NAME:-Forge} Workflow",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "${message}"
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "Sent: $(date '+%Y-%m-%d %H:%M:%S') | Repo: \`${FORGE_PROJECT_NAME:-unknown}\`"
        }
      ]
    }
  ]
}
EOF
)

  HTTP_CODE=$(curl -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "%{http_code}" \
    -s -o /dev/null 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Slack notification sent"
    return 0
  else
    echo "⚠️  Slack notification failed (HTTP $HTTP_CODE)"
    return 1
  fi
}

# Send email notification via AWS SES
send_email() {
  local subject="$1"
  local message="$2"
  local urgency="${3:-normal}"

  if [ -z "$EMAIL_ADDRESS" ]; then
    echo "⚠️  EMAIL_NOTIFICATION_ADDRESS not set, skipping email"
    return 0
  fi

  if [ -z "$FORGE_EMAIL_FROM" ]; then
    echo "⚠️  FORGE_EMAIL_FROM not set, skipping email"
    return 0
  fi

  # Add urgency to subject
  [ "$urgency" = "urgent" ] && subject="🚨 URGENT: $subject"

  aws ses send-email \
    --from "$FORGE_EMAIL_FROM" \
    --to "$EMAIL_ADDRESS" \
    --subject "$subject" \
    --text "$message" \
    --profile "$AWS_PROFILE" \
    2>/dev/null

  if [ $? -eq 0 ]; then
    echo "✅ Email sent to $EMAIL_ADDRESS"
    return 0
  else
    echo "⚠️  Email failed (check AWS SES configuration)"
    return 1
  fi
}

# Send SMS via AWS SNS (only for urgent notifications)
send_sms() {
  local message="$1"

  if [ -z "$SNS_TOPIC_ARN" ]; then
    echo "⚠️  FORGE_SNS_TOPIC_ARN not set, skipping SMS"
    return 1
  fi

  # Truncate message to 140 chars (SMS limit)
  local short_message=$(echo "$message" | head -c 140)

  aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --message "$short_message" \
    --profile "$AWS_PROFILE" \
    2>/dev/null

  if [ $? -eq 0 ]; then
    echo "✅ SMS sent"
    return 0
  else
    echo "⚠️  SMS failed (SNS may be in sandbox mode)"
    return 1
  fi
}

# Send notification to all channels
send_notification_all() {
  local message="$1"
  local urgency="${2:-normal}"  # normal or urgent

  echo ""
  echo "📢 Sending notifications ($urgency)..."

  # Always send to Slack and Email
  send_slack "$message" "$urgency"

  # Format message for email (convert markdown to plain text)
  local email_message=$(echo "$message" | sed 's/\*\*//g' | sed 's/`//g' | sed 's/^#\+ //')
  local email_subject=$(echo "$email_message" | head -1 | cut -c 1-50)
  send_email "$email_subject" "$email_message" "$urgency"

  # Only send SMS for urgent notifications
  if [ "$urgency" = "urgent" ]; then
    send_sms "$message"
  fi

  echo ""
}

# Send blocker notification with context
send_blocker_notification() {
  local blocker_type="$1"
  local issue_number="$2"
  local pr_number="${3:-}"
  local worktree_path="${4:-}"
  local details="${5:-}"

  # Build resume command
  local resume_cmd="forge ${issue_number}"
  if [[ "$issue_number" == batch-* ]]; then
    # Extract actual issue number from batch-XX format
    local actual_issue="${issue_number#batch-}"
    resume_cmd="forge ${actual_issue}"
  fi

  # Get repo URL for clickable links
  local repo_url
  repo_url=$(gh repo view --json url --jq '.url' 2>/dev/null || echo "")

  # Check if this blocker type is bypassable in supervised mode
  local bypass_hint=""
  case "$blocker_type" in
    auth_changes|architectural_docs|protected_scripts|infrastructure|database_migration|expensive_services)
      bypass_hint="
_To bypass: \`${resume_cmd} --supervised\` (terminal warnings) or \`${resume_cmd} --bypass-blockers\` (Slack warnings)_"
      ;;
  esac

  local message=":rotating_light: *Workflow Blocker Detected*

*Type:* ${blocker_type}
*Issue:* $([ -n "$repo_url" ] && echo "<${repo_url}/issues/${issue_number}|#${issue_number}>" || echo "#${issue_number}")
$([ -n "$pr_number" ] && [ -n "$repo_url" ] && echo "*PR:* <${repo_url}/pull/${pr_number}|#${pr_number}>" || ([ -n "$pr_number" ] && echo "*PR:* #${pr_number}"))
$([ -n "$worktree_path" ] && echo "*Worktree:* \`${worktree_path}\`")

*Details:*
${details}

*To Resume:*
\`\`\`
${resume_cmd}
\`\`\`${bypass_hint}

*Blocker occurred:* $(date '+%Y-%m-%d %H:%M:%S')"

  send_notification_all "$message" "urgent"
}

# Send completion notification
send_completion_notification() {
  local issue_number="$1"
  local pr_number="$2"
  local pr_title="$3"
  local files_changed="${4:-?}"
  local followup_issues="${5:-0}"

  # Get repo URL for clickable links
  local repo_url
  repo_url=$(gh repo view --json url --jq '.url' 2>/dev/null || echo "")

  local message="✅ *Issue $([ -n "$repo_url" ] && echo "<${repo_url}/issues/${issue_number}|#${issue_number}>" || echo "#${issue_number}") Complete*

*PR $([ -n "$repo_url" ] && echo "<${repo_url}/pull/${pr_number}|#${pr_number}>" || echo "#${pr_number}"):* ${pr_title}
*Files Changed:* ${files_changed}
*Follow-up Issues:* ${followup_issues}

*Actions Taken:*
• Code implemented and tested
• PR created and reviewed
• Security guide updated
• Branch merged and cleaned up

*Completed:* $(date '+%Y-%m-%d %H:%M:%S')"

  send_notification_all "$message" "normal"
}

# Send batch progress notification
send_batch_progress() {
  local completed="$1"
  local total="$2"
  local current_issue="$3"
  local elapsed_time="$4"

  local percent=$((completed * 100 / total))

  local message="🔄 *Batch Processing Update*

*Progress:* ${completed}/${total} issues (${percent}%)
*Current:* Issue #${current_issue}
*Elapsed:* ${elapsed_time}

*Status:* Working autonomously..."

  send_slack "$message" "normal"
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f send_slack
  export -f send_email
  export -f send_sms
  export -f send_notification_all
  export -f send_blocker_notification
  export -f send_completion_notification
  export -f send_batch_progress
fi
