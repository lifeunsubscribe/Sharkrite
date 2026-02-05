#!/bin/bash
# lib/utils/blocker-rules.sh
# The 10 Blocker Rules - automatic workflow stopping conditions
# Usage: source this file and call check_blockers()
#
# Requires: config.sh sourced first (for $BLOCKER_* pattern variables)

# Source notifications library
source "$RITE_LIB_DIR/utils/notifications.sh"

# Blocker detection functions

detect_infrastructure_changes() {
  local pr_number=$1

  # Use configurable path pattern from blocker config
  local infra_pattern="$BLOCKER_INFRASTRUCTURE_PATHS"
  local infra_files=$(gh pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${infra_pattern}\")) | .path" 2>/dev/null || echo "")

  if [ -n "$infra_files" ]; then
    echo "BLOCKER: Infrastructure changes detected"
    echo "Files: $(echo "$infra_files" | tr '\n' ', ')"
    return 1
  fi

  return 0
}

detect_database_migrations() {
  local pr_number=$1

  # Use configurable path pattern
  local migration_pattern="$BLOCKER_MIGRATION_PATHS"
  local migration_files=$(gh pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${migration_pattern}\")) | .path" 2>/dev/null || echo "")

  if [ -n "$migration_files" ]; then
    echo "BLOCKER: Database migration detected"
    echo "Migrations: $(echo "$migration_files" | tr '\n' ', ')"

    # Show migration SQL if available
    echo ""
    echo "Migration diff:"
    gh pr diff "$pr_number" 2>/dev/null | head -50

    return 1
  fi

  return 0
}

detect_auth_changes() {
  local pr_number=$1

  # Use configurable auth pattern (exclude tests and docs)
  local auth_pattern="$BLOCKER_AUTH_PATHS"
  local auth_files=$(gh pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${auth_pattern}\")) | select(.path | test(\"tests?/|docs?/\") | not) | .path" 2>/dev/null || echo "")

  if [ -n "$auth_files" ]; then
    echo "BLOCKER: Authentication/authorization code changes detected"
    echo "Files: $(echo "$auth_files" | tr '\n' ', ')"
    echo ""
    echo "Auth changes require extra security review"
    echo "Tip: Run in supervised mode (forge <issue> --supervised) to review and approve manually"
    return 1
  fi

  return 0
}

detect_doc_changes() {
  local pr_number=$1

  # Use configurable doc pattern
  local doc_pattern="$BLOCKER_DOC_PATHS"
  local doc_files=$(gh pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${doc_pattern}\")) | .path" 2>/dev/null || echo "")

  if [ -n "$doc_files" ]; then
    echo "BLOCKER: Architectural documentation changes detected"
    echo "Docs: $(echo "$doc_files" | tr '\n' ', ')"
    echo ""
    echo "Architecture changes may require manual review"
    echo "Tip: Run in supervised mode (forge <issue> --supervised) to review and approve manually"
    return 1
  fi

  return 0
}

detect_critical_issues() {
  local pr_number=$1

  # Get latest review from bot users
  local review=$(gh pr view "$pr_number" --json comments --jq '[.comments[] | select(.author.login | test("claude|github-actions"; "i"))] | .[-1] | .body' 2>/dev/null || echo "")

  if [ -z "$review" ]; then
    return 0  # No review yet, not a blocker
  fi

  # Parse CRITICAL count
  local critical_count=$(echo "$review" | grep -oiE 'CRITICAL[[:space:]:]+\(?[0-9]+\)?' | grep -oE '[0-9]+' | head -1)
  critical_count=${critical_count:-0}

  if [ "$critical_count" -gt 0 ]; then
    echo "BLOCKER: CRITICAL issues found in review ($critical_count)"
    echo ""
    echo "CRITICAL issues must be fixed before merge"
    return 1
  fi

  return 0
}

detect_test_failures() {
  local exit_code=$1
  local test_output="${2:-/tmp/test-output.log}"

  if [ "$exit_code" -ne 0 ]; then
    echo "BLOCKER: Tests failed (exit code: $exit_code)"
    echo ""
    echo "Failed tests:"
    [ -f "$test_output" ] && tail -50 "$test_output"
    return 1
  fi

  return 0
}

detect_expensive_services() {
  local pr_number=$1

  # Use configurable service pattern against infrastructure files
  local expensive_pattern="$BLOCKER_EXPENSIVE_SERVICES"
  local infra_pattern="$BLOCKER_INFRASTRUCTURE_PATHS"

  # Get diff of infrastructure files only
  local expensive=$(gh pr diff "$pr_number" 2>/dev/null | grep -iE "$expensive_pattern" || echo "")

  if [ -n "$expensive" ]; then
    echo "BLOCKER: Expensive cloud service detected"
    echo ""
    echo "Services found:"
    echo "$expensive" | grep -oiE "$expensive_pattern" | sort -u
    echo ""
    echo "This may significantly increase costs"
    return 1
  fi

  return 0
}

detect_session_limit() {
  local issues_completed="${1:-0}"
  local elapsed_hours="${2:-0}"

  if [ "$issues_completed" -ge "${RITE_MAX_ISSUES_PER_SESSION:-8}" ]; then
    echo "BLOCKER: Approaching token limit ($issues_completed issues completed)"
    echo ""
    echo "Starting fresh session to prevent quality degradation"
    return 1
  fi

  if [ "$elapsed_hours" -ge "${RITE_MAX_SESSION_HOURS:-4}" ]; then
    echo "BLOCKER: Approaching session time limit (${elapsed_hours} hours elapsed)"
    echo ""
    echo "Saving state for next session"
    return 1
  fi

  return 0
}

detect_credentials_expired() {
  # Check AWS credentials using configured profile
  if ! aws sts get-caller-identity --profile "${RITE_AWS_PROFILE:-default}" &>/dev/null; then
    return 1
  fi

  return 0
}

detect_protected_scripts() {
  local pr_number=$1

  # Use configurable protected script pattern
  local protected_pattern="$BLOCKER_PROTECTED_SCRIPTS"

  # Convert pipe-separated pattern to array for iteration
  IFS='|' read -ra protected_scripts <<< "$protected_pattern"

  for script in "${protected_scripts[@]}"; do
    local changes=$(gh pr view "$pr_number" --json files --jq ".files[] | select(.path | contains(\"$script\")) | .path" 2>/dev/null || echo "")

    if [ -n "$changes" ]; then
      echo "BLOCKER: Protected script changed: $script"
      echo ""
      echo "Changes to workflow automation scripts require manual review"
      echo "Tip: Run in supervised mode (--supervised) to review and approve merge manually"
      echo ""
      echo "Diff:"
      gh pr diff "$pr_number" -- "*/$script" 2>/dev/null | head -100
      return 1
    fi
  done

  return 0
}

# Main blocker check function
check_blockers() {
  local context="$1"  # "pre-start", "pre-commit", "pre-merge", "session-check"
  local pr_number="${2:-}"
  local issue_number="${3:-}"
  local workflow_mode="${4:-unsupervised}"

  local blocker_detected=false
  local blocker_type=""
  local blocker_details=""

  case "$context" in
    pre-start)
      # Check session and credentials before starting
      if [ "${SKIP_AWS_CHECK:-true}" != "true" ]; then
        if ! detect_credentials_expired; then
          blocker_type="credentials_expired"
          blocker_details="AWS credentials are expired"
          blocker_detected=true
        fi
      fi
      ;;

    pre-commit)
      # Check before committing code (currently no pre-commit blockers)
      ;;

    pre-merge)
      # Comprehensive checks before merging PR
      if [ -z "$pr_number" ]; then
        echo "PR number required for pre-merge checks" >&2
        return 1
      fi

      # Run all PR-based checks
      if ! detect_infrastructure_changes "$pr_number"; then
        blocker_type="infrastructure"
        blocker_details=$(detect_infrastructure_changes "$pr_number" 2>&1)
        blocker_detected=true
      elif ! detect_database_migrations "$pr_number"; then
        blocker_type="database_migration"
        blocker_details=$(detect_database_migrations "$pr_number" 2>&1)
        blocker_detected=true
      elif ! detect_auth_changes "$pr_number"; then
        blocker_type="auth_changes"
        blocker_details=$(detect_auth_changes "$pr_number" 2>&1)
        blocker_detected=true
      elif ! detect_doc_changes "$pr_number"; then
        blocker_type="architectural_docs"
        blocker_details=$(detect_doc_changes "$pr_number" 2>&1)
        blocker_detected=true
      elif ! detect_critical_issues "$pr_number"; then
        blocker_type="critical_issues"
        blocker_details=$(detect_critical_issues "$pr_number" 2>&1)
        blocker_detected=true
      elif ! detect_expensive_services "$pr_number"; then
        blocker_type="expensive_services"
        blocker_details=$(detect_expensive_services "$pr_number" 2>&1)
        blocker_detected=true
      elif ! detect_protected_scripts "$pr_number"; then
        blocker_type="protected_scripts"
        blocker_details=$(detect_protected_scripts "$pr_number" 2>&1)
        blocker_detected=true
      fi
      ;;

    session-check)
      # Check session limits during processing
      local issues_completed="${pr_number:-0}"  # Reuse param
      local elapsed_hours="${issue_number:-0}"  # Reuse param

      if ! detect_session_limit "$issues_completed" "$elapsed_hours"; then
        blocker_type="session_limit"
        blocker_details=$(detect_session_limit "$issues_completed" "$elapsed_hours" 2>&1)
        blocker_detected=true
      elif [ "${SKIP_AWS_CHECK:-true}" != "true" ] && ! detect_credentials_expired; then
        blocker_type="credentials_expired"
        blocker_details="AWS credentials expired during processing"
        blocker_detected=true
      fi
      ;;
  esac

  # If blocker detected, export details for handle_blocker
  if [ "$blocker_detected" = true ]; then
    export BLOCKER_TYPE="$blocker_type"
    export BLOCKER_DETAILS="$blocker_details"
    return 1
  fi

  return 0
}

# Categorize blocker urgency
get_blocker_urgency() {
  local blocker_type="$1"

  case "$blocker_type" in
    infrastructure|database_migration|auth_changes|architectural_docs|expensive_services|protected_scripts)
      echo "urgent"
      ;;
    critical_issues)
      echo "high"
      ;;
    session_limit|credentials_expired)
      echo "normal"
      ;;
    *)
      echo "normal"
      ;;
  esac
}

# Determine if blocker blocks other issues in batch
is_blocking_batch() {
  local blocker_type="$1"

  case "$blocker_type" in
    credentials_expired|session_limit)
      echo "true"  # These block the entire batch
      ;;
    *)
      echo "false"  # These only block current issue
      ;;
  esac
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f detect_infrastructure_changes
  export -f detect_database_migrations
  export -f detect_auth_changes
  export -f detect_doc_changes
  export -f detect_critical_issues
  export -f detect_test_failures
  export -f detect_expensive_services
  export -f detect_session_limit
  export -f detect_credentials_expired
  export -f detect_protected_scripts
  export -f check_blockers
  export -f get_blocker_urgency
  export -f is_blocking_batch
fi
