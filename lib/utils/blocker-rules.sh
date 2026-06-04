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

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f detect_infrastructure_changes >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source notifications library
source "$RITE_LIB_DIR/utils/notifications.sh"

# Source gh retry wrapper if not already loaded
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# Blocker detection functions

detect_infrastructure_changes() {
  local pr_number=$1

  # Use configurable path pattern from blocker config
  local infra_pattern="$BLOCKER_INFRASTRUCTURE_PATHS"
  local infra_files
  infra_files=$(gh_safe pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${infra_pattern}\")) | .path")
  infra_files="${infra_files:-}"

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
  local migration_files
  migration_files=$(gh_safe pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${migration_pattern}\")) | .path")
  migration_files="${migration_files:-}"

  if [ -n "$migration_files" ]; then
    echo "BLOCKER: Database migration detected"
    echo "Migrations:"
    echo "$migration_files" | sed 's/^/  /'

    # Show migration SQL if available
    echo ""
    echo "Migration diff:"
    gh_safe pr diff "$pr_number" 2>/dev/null | head -50

    return 1
  fi

  return 0
}

detect_auth_changes() {
  local pr_number=$1

  # Use configurable auth pattern (exclude tests and docs)
  local auth_pattern="$BLOCKER_AUTH_PATHS"
  local auth_files
  auth_files=$(gh_safe pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${auth_pattern}\")) | select(.path | test(\"tests?/|docs?/\") | not) | .path")
  auth_files="${auth_files:-}"

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
  local doc_files
  doc_files=$(gh_safe pr view "$pr_number" --json files --jq ".files[] | select(.path | test(\"${doc_pattern}\")) | .path")
  doc_files="${doc_files:-}"

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
  local review
  review=$(gh_safe pr view "$pr_number" --json comments --jq '[.comments[] | select(.author.login | test("claude|github-actions"; "i"))] | .[-1] | .body')
  review="${review:-}"

  if [ -z "$review" ]; then
    return 0  # No review yet, not a blocker
  fi

  # Parse CRITICAL count
  local critical_count=$(echo "$review" | grep -oiE 'CRITICAL[[:space:]:]+\(?[0-9]+\)?' | grep -oE '[0-9]+' | head -1 || true)
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
  local expensive
  expensive=$(gh_safe pr diff "$pr_number" | grep -iE "$expensive_pattern" || true)
  expensive="${expensive:-}"

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

# detect_session_limit ISSUES_COMPLETED CUMULATIVE_WORK_HOURS
#
# Hard gate: fires when the session has burned through too many issues or
# too many hours of ACTIVE work.
#
# IMPORTANT — what "hours" means here (issue #283):
#   CUMULATIVE_WORK_HOURS is the sum of per-issue durations tracked by
#   start_issue_tracking / end_issue_tracking in session-tracker.sh.
#   It measures time actually spent running rite workflows, NOT wall-clock
#   age since the session state file was written. A 40-hour-old zombie state
#   file with 0 issues run contributes 0 to cumulative_work_hours.
#
# Default: RITE_MAX_SESSION_HOURS=12 (raised from 4 — 4h of active work
# was realistic for wall-clock, but cumulative active work is a much tighter
# signal; 12h represents a full dev-day of rite automation).
detect_session_limit() {
  local issues_completed="${1:-0}"
  local cumulative_work_hours="${2:-0}"

  if [ "$issues_completed" -ge "${RITE_MAX_ISSUES_PER_SESSION:-8}" ]; then
    echo "BLOCKER: Approaching token limit ($issues_completed issues completed)"
    echo ""
    echo "Starting fresh session to prevent quality degradation"
    return 1
  fi

  if [ "$cumulative_work_hours" -ge "${RITE_MAX_SESSION_HOURS:-12}" ]; then
    echo "BLOCKER: Cumulative active work limit reached (${cumulative_work_hours}h of active work in this session)"
    echo ""
    echo "Saving state for next session"
    return 1
  fi

  return 0
}

# detect_issue_duration_limit ISSUE_NUMBER CURRENT_ISSUE_ELAPSED_HOURS
#
# Hard gate: fires when a single issue has been running longer than
# RITE_MAX_ISSUE_HOURS (default: 4h). This protects against runaway fix
# loops and yak-shaves within a single issue.
#
# Called from the session-check context in workflow-runner.sh, where
# CURRENT_ISSUE_ELAPSED_HOURS is computed from get_current_issue_elapsed_seconds.
detect_issue_duration_limit() {
  local issue_number="${1:-?}"
  local current_issue_elapsed_hours="${2:-0}"

  if [ "$current_issue_elapsed_hours" -ge "${RITE_MAX_ISSUE_HOURS:-4}" ]; then
    echo "BLOCKER: Issue #${issue_number} has been running >${current_issue_elapsed_hours}h — likely stuck in fix loop or yak-shave"
    echo ""
    echo "Stop and review the issue manually. To continue anyway:"
    echo "  rite ${issue_number} --bypass-blockers"
    return 1
  fi

  return 0
}

detect_aws_project() {
  # Detect whether this repo uses AWS by checking for local indicators.
  # Fast, zero API calls. Cached per session via RITE_AWS_PROJECT.
  if [ -n "${RITE_AWS_PROJECT:-}" ]; then
    [ "$RITE_AWS_PROJECT" = "true" ]
    return $?
  fi

  local project_root="${RITE_PROJECT_ROOT:-.}"

  # IaC markers (most definitive signal)
  for marker in cdk.json samconfig.toml serverless.yml serverless.yaml template.yaml template.yml; do
    if [ -f "$project_root/$marker" ]; then
      export RITE_AWS_PROJECT=true
      return 0
    fi
  done

  # Terraform with AWS provider
  if find "$project_root" -maxdepth 2 -name '*.tf' -print -quit 2>/dev/null | grep -q . && \
     grep -rlq 'provider\s*"aws"' "$project_root" --include='*.tf' --max-depth=2 2>/dev/null; then
    export RITE_AWS_PROJECT=true
    return 0
  fi

  # Dependency manifests — only counts as AWS project if ALSO has IaC markers.
  # Having boto3 as a library dependency doesn't mean the project deploys to AWS
  # or needs credentials at runtime. Require at least one IaC file (checked above)
  # to promote a dependency-only match. Without IaC, silently skip.
  # Projects can override with RITE_AWS_PROJECT=true in .rite/config.

  export RITE_AWS_PROJECT=false
  return 1
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
    local changes
    changes=$(gh_safe pr view "$pr_number" --json files --jq ".files[] | select(.path | contains(\"$script\")) | .path")
    changes="${changes:-}"

    if [ -n "$changes" ]; then
      echo "BLOCKER: Protected script changed: $script"
      echo ""
      echo "Changes to workflow automation scripts require manual review"
      if [ "${WORKFLOW_MODE:-}" != "supervised" ]; then
        echo "Tip: Run in supervised mode (--supervised) to review and approve merge manually"
      fi
      echo ""
      echo "Diff:"
      gh_safe pr diff "$pr_number" -- "*/$script" 2>/dev/null | head -100
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
  changed_files=$(gh_safe pr view "$pr_number" --json files --jq '.files[].path')
  changed_files="${changed_files:-}"

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

For auth code specifically, check each of the following — these are the most common auth vulnerabilities and should be verified even if not cited in the diff:
- **Timing attacks**: Does any auth failure return immediately without doing equivalent work? (e.g. skipping password hash for non-existent users leaks email existence via timing)
- **Role/privilege assignment**: Is the role or permission level assigned from user-supplied input? Can a user self-elevate? Check every place the role field is written, not just the validation layer.
- **Input normalization**: Are emails/usernames lowercased consistently before lookup and storage? Case-inconsistent lookups create duplicate accounts and auth bypasses.
- **Partial fix gaps**: If this PR includes prior fixes, check that the fix was applied everywhere the vulnerable pattern appears — not just the cited line.

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
  expensive_matches=$(gh_safe pr diff "$pr_number" | grep -oiE "$BLOCKER_EXPENSIVE_SERVICES" | sort -u || true)
  expensive_matches="${expensive_matches:-}"
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
  protected_matches=$(echo "$protected_matches" | sed '/^$/d' || true)
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
      # Re-validate AWS credentials when resuming from a credentials_expired blocker.
      # Only runs for AWS projects (detect_aws_project is cached after the first call).
      # For all other resume reasons this context remains a no-op.
      if [ "${RESUME_BLOCKER_REASON:-}" = "credentials_expired" ] && detect_aws_project; then
        if ! detect_credentials_expired; then
          blocker_type="credentials_expired"
          blocker_details="AWS credentials are still expired. Refresh credentials and re-run."
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
      # Check session limits during processing.
      # pr_number and issue_number params are repurposed here (no PR context):
      #   pr_number     = issues_completed count
      #   issue_number  = cumulative_work_hours (active work, not wall-clock)
      #   workflow_mode = current issue number (for per-issue cap message)
      local issues_completed="${pr_number:-0}"
      local cumulative_work_hours="${issue_number:-0}"
      local current_issue_for_check="${workflow_mode:-}"

      if ! detect_session_limit "$issues_completed" "$cumulative_work_hours"; then
        blocker_type="session_limit"
        blocker_details=$(detect_session_limit "$issues_completed" "$cumulative_work_hours" 2>&1)
        blocker_detected=true
      # Per-issue duration cap: only check when an issue is actively tracked
      elif [ -n "$current_issue_for_check" ]; then
        local _issue_elapsed_secs
        _issue_elapsed_secs=$(get_current_issue_elapsed_seconds 2>/dev/null || echo "0")
        local _issue_elapsed_hours=$(( _issue_elapsed_secs / 3600 ))
        if ! detect_issue_duration_limit "$current_issue_for_check" "$_issue_elapsed_hours"; then
          blocker_type="session_limit"
          blocker_details=$(detect_issue_duration_limit "$current_issue_for_check" "$_issue_elapsed_hours" 2>&1)
          blocker_detected=true
        fi
      fi
      # AWS creds not checked here — test failures catch real AWS dependency issues
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
  export -f detect_issue_duration_limit
  export -f detect_aws_project
  export -f detect_credentials_expired
  export -f detect_protected_scripts
  export -f detect_sensitivity_areas
  export -f check_blockers
  export -f get_blocker_urgency
  export -f is_blocking_batch
fi
