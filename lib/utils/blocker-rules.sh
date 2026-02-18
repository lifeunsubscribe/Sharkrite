#!/bin/bash
# lib/utils/blocker-rules.sh
# Two-tier safety system: review sensitivity hints + hard merge gates
#
# Sensitivity hints (path-based): inject focus areas into the review prompt
#   infrastructure, migrations, auth, docs, expensive services, protected scripts
#
# Hard gates (content-aware): block merges until resolved
#   critical review findings, test failures, session limits, credential expiry
#
# Usage: source this file, call check_blockers() for gates or
#        detect_sensitivity_areas() for review hints
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
    echo "Files:"
    echo "$infra_files" | sed 's/^/  /'
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
    echo "Migrations:"
    echo "$migration_files" | sed 's/^/  /'

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
    echo "Files:"
    echo "$auth_files" | sed 's/^/  /'
    echo ""
    echo "Auth changes require extra security review"
    if [ "${WORKFLOW_MODE:-}" != "supervised" ]; then
      echo "Tip: Run in supervised mode (rite <issue> --supervised) to review and approve manually"
    fi
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
    echo "Docs:"
    echo "$doc_files" | sed 's/^/  /'
    echo ""
    echo "Architecture changes may require manual review"
    if [ "${WORKFLOW_MODE:-}" != "supervised" ]; then
      echo "Tip: Run in supervised mode (rite <issue> --supervised) to review and approve manually"
    fi
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
      if [ "${WORKFLOW_MODE:-}" != "supervised" ]; then
        echo "Tip: Run in supervised mode (--supervised) to review and approve merge manually"
      fi
      echo ""
      echo "Diff:"
      gh pr diff "$pr_number" -- "*/$script" 2>/dev/null | head -100
      return 1
    fi
  done

  return 0
}

# Detect sensitivity areas for review enhancement.
# Fetches changed files once, matches all patterns in memory, returns
# structured hints on stdout. Always exits 0 (informational, never blocks).
detect_sensitivity_areas() {
  local pr_number=$1
  local hints=""

  # Fetch changed file paths once (single API call)
  local changed_files
  changed_files=$(gh pr view "$pr_number" --json files --jq '.files[].path' 2>/dev/null || echo "")

  if [ -z "$changed_files" ]; then
    return 0
  fi

  # Infrastructure
  local infra_matches
  infra_matches=$(echo "$changed_files" | grep -iE "$BLOCKER_INFRASTRUCTURE_PATHS" || true)
  if [ -n "$infra_matches" ]; then
    hints+="### Sensitivity: Infrastructure Changes
Files:
$(echo "$infra_matches" | sed 's/^/  /')
Guidance: Verify infrastructure changes are intentional and correctly scoped. Check for missing environment guards, unintended production impact, and appropriate cost controls.

"
  fi

  # Database migrations
  local migration_matches
  migration_matches=$(echo "$changed_files" | grep -iE "$BLOCKER_MIGRATION_PATHS" || true)
  if [ -n "$migration_matches" ]; then
    hints+="### Sensitivity: Database Migrations
Files:
$(echo "$migration_matches" | sed 's/^/  /')
Guidance: Verify migration is reversible or has a rollback plan. Check for data loss risk in column drops or type changes. Confirm indexes for new foreign keys and correct migration ordering.

"
  fi

  # Auth changes (exclude tests and docs, same as the detector)
  local auth_matches
  auth_matches=$(echo "$changed_files" | grep -iE "$BLOCKER_AUTH_PATHS" | grep -viE "tests?/|docs?/" || true)
  if [ -n "$auth_matches" ]; then
    hints+="### Sensitivity: Authentication / Authorization
Files:
$(echo "$auth_matches" | sed 's/^/  /')
Guidance: Verify no changes to authentication flow, token validation, session management, or authorization checks. Distinguish whether control flow was modified vs. only logging, formatting, or error message changes.

"
  fi

  # Architectural docs
  local doc_matches
  doc_matches=$(echo "$changed_files" | grep -iE "$BLOCKER_DOC_PATHS" || true)
  if [ -n "$doc_matches" ]; then
    hints+="### Sensitivity: Architectural Documentation
Files:
$(echo "$doc_matches" | sed 's/^/  /')
Guidance: Verify documentation changes accurately reflect the current system state. Check for outdated references or incorrect behavioral descriptions.

"
  fi

  # Expensive services (scan diff for service names)
  local expensive_matches
  expensive_matches=$(gh pr diff "$pr_number" 2>/dev/null | grep -oiE "$BLOCKER_EXPENSIVE_SERVICES" | sort -u || true)
  if [ -n "$expensive_matches" ]; then
    hints+="### Sensitivity: Expensive Cloud Services
Services referenced:
$(echo "$expensive_matches" | sed 's/^/  /')
Guidance: Verify cost implications of referenced cloud services. Check for appropriate instance sizing, auto-scaling limits, and lifecycle policies.

"
  fi

  # Protected scripts
  local protected_matches=""
  IFS='|' read -ra _protected_list <<< "$BLOCKER_PROTECTED_SCRIPTS"
  for _script in "${_protected_list[@]}"; do
    local _match
    _match=$(echo "$changed_files" | grep -F "$_script" || true)
    if [ -n "$_match" ]; then
      protected_matches+="$_match"$'\n'
    fi
  done
  protected_matches=$(echo "$protected_matches" | sed '/^$/d')
  if [ -n "$protected_matches" ]; then
    hints+="### Sensitivity: Workflow Scripts Modified
Files:
$(echo "$protected_matches" | sed 's/^/  /')
Guidance: Verify changes do not break the CI/CD pipeline, review loop, or merge process. Check for regressions in error handling and exit code propagation.

"
  fi

  if [ -n "$hints" ]; then
    echo "$hints"
  fi

  return 0
}

# Main blocker check function (hard gates only)
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

      # Content-aware hard gates only. Path-based checks (infrastructure,
      # migrations, auth, docs, expensive services, protected scripts) are now
      # handled as review sensitivity hints via detect_sensitivity_areas().
      local _det_output
      local _det_checks=("critical_issues:detect_critical_issues")

      for _check in "${_det_checks[@]}"; do
        local _type="${_check%%:*}"
        local _func="${_check##*:}"
        _det_output=$($_func "$pr_number" 2>&1) || {
          blocker_type="$_type"
          blocker_details="$_det_output"
          blocker_detected=true
          break
        }
      done
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
  export -f detect_sensitivity_areas
  export -f check_blockers
  export -f get_blocker_urgency
  export -f is_blocking_batch
fi
