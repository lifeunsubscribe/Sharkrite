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

# Re-source guard: skip if already loaded (idempotent sourcing).
#
# Variable-based, NOT function-sentinel, because this file `export -f`s its
# function set (lines 794-810). With a `declare -f <fn>` guard, a subprocess
# of a batch parent that sourced an OLDER blocker-rules.sh inherits the parent's
# exported function (sentinel match) and short-circuits — never defining functions
# added to the file after the parent started. Live failure: PR #350 added
# detect_lib_shrinkage mid-batch on 2026-06-04 → #351/#352 failed in create-pr.sh
# with "detect_lib_shrinkage: command not found".
#
# The variable is deliberately NOT exported. Same-shell re-sources see it set
# (guard fires, no double-load). True subprocesses see it unset (guard misses,
# they re-source against the current on-disk file). Subshells via `( ... )` inherit
# it — that's fine, they share the parent's function set verbatim.
#
# DO NOT `export _RITE_BLOCKER_RULES_LOADED`. Regression test in
# tests/regression/blocker-rules-stale-inherited-functions.bats asserts this.
if [ "${_RITE_BLOCKER_RULES_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_BLOCKER_RULES_LOADED=true

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

  # Issue-count cap removed (was stale heuristic with misleading "token limit"
  # message; no token measurement behind it). The real spending cap is exit
  # code 5 from provider_run_agentic_session in lib/providers/claude.sh.

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

# detect_lib_shrinkage PR_NUMBER
#
# Hard gate: fires when a PR deletes a large fraction of a production lib/ file.
#
# Triggered when ANY file under lib/core/, lib/utils/, or lib/providers/ loses:
#   - More than 50% of its total line count, OR
#   - More than 500 lines (absolute)
#
# This check exists because auto-review-driven PRs (rite --fix-review) can
# silently overwrite production code if a buggy test writes through a symlink
# or if Claude applies overly-aggressive deletions.  The 2026-06-02 incident
# (PR #260) deleted 1,256 lines of production lib/ code without human review.
#
# Thresholds are configurable via env vars:
#   RITE_SHRINKAGE_RATIO_PCT   — default 50  (percent, integer)
#   RITE_SHRINKAGE_ABS_LINES   — default 500 (lines, integer)
#
# Diff counting: we count deleted lines (^-) via awk over `gh pr diff` output.
# The API `.files[].deletions` field is intentionally NOT used here — the diff
# count and the API count can diverge, and using two sources for the same metric
# would cause the same file to appear twice with conflicting deletion tallies.
# A single awk pass produces all per-file deletion counts; both the absolute and
# ratio checks run against those values.
#
# Per-file total line count uses `git show origin/<base_branch>:<path> | wc -l`
# to get the pre-deletion baseline from the PR's actual base branch.  The base
# branch is resolved dynamically from the PR via `gh pr view --json baseRefName`
# so that PRs targeting non-main branches use the correct baseline.  A fetch is
# attempted before the git show so a stale/unfetched ref does not silently skip
# the ratio check.  Using `wc -l` on the local worktree file would produce the
# post-deletion count, making the ratio denominator too small and potentially
# producing percentages above 100%.
# If the file has no entry on the base branch (new file added in this PR), the
# ratio check is skipped and only the absolute threshold applies.
#
# Returns 1 (blocker) on first file that exceeds a threshold.
# Exports SHRINKAGE_BLOCKER_FILE, SHRINKAGE_BLOCKER_DELETED, SHRINKAGE_BLOCKER_TOTAL.
# Logs a structured [diag] line to RITE_LOG_FILE for the health report.
detect_lib_shrinkage() {
  local pr_number=$1

  # Default thresholds — overridable via env/config
  local ratio_pct="${RITE_SHRINKAGE_RATIO_PCT:-50}"
  local abs_lines="${RITE_SHRINKAGE_ABS_LINES:-500}"

  # Resolve the PR's actual base branch dynamically so that non-main-base PRs
  # use the correct baseline ref.  Falls back to "main" if the API call fails
  # (network error, PR not found) so the check degrades rather than crashes.
  local base_branch
  base_branch=$(gh_safe pr view "$pr_number" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
  base_branch="${base_branch:-main}"

  # Attempt a fetch of the base branch before git show so a stale or never-fetched
  # ref does not silently cause the ratio check to skip.  This is best-effort —
  # if the fetch fails (e.g. offline, no permissions) we proceed and let the
  # git show empty-output path handle the miss transparently with a [diag] log.
  git -C "${RITE_PROJECT_ROOT:-.}" fetch origin "$base_branch" --quiet 2>/dev/null || true

  # Production path prefix pattern (matches lib/core/, lib/utils/, lib/providers/)
  local prod_path_re="^(lib/core|lib/utils|lib/providers)/"

  # Fetch the diff once; extract only lines that affect production lib files
  # Use gh pr diff which gives us unified diff text we can parse portably.
  local diff_text
  diff_text=$(gh_safe pr diff "$pr_number" 2>/dev/null || true)

  if [ -z "$diff_text" ]; then
    return 0  # Empty diff is not an error — PR may have no file changes
  fi

  # Parse the diff: for each file matching the production path, count deletions.
  # We walk the diff line by line, tracking the current file and counting ^- lines.
  #
  # diff --git a/lib/core/foo.sh b/lib/core/foo.sh   ← new file section (normal)
  # diff --git a/lib/core/old.sh b/lib/core/new.sh   ← rename header
  # similarity index 100%                             ← pure rename (no content changes)
  # rename from lib/core/old.sh
  # rename to lib/core/new.sh
  # --- a/lib/core/foo.sh                              ← may also appear
  # -deleted line                                      ← count these
  #
  # Path extraction: we split on " b/" rather than using $NF so that paths
  # containing spaces are handled correctly.  $NF would return only the last
  # whitespace-delimited token (e.g. "bar.sh" for "lib/core/foo bar.sh").
  #
  # Rename handling: "rename to <path>" updates current_file so cross-directory
  # renames are attributed to the destination path (which determines whether the
  # file is still in lib/core|utils|providers after the rename).  Pure renames
  # (similarity index 100%) have no diff body, so deleted stays 0 naturally;
  # we still track them in case later processing adds lines.
  #
  # Use awk for portability (no bash 4+ required, works on macOS awk/gawk).
  # Write the awk program to a temp file so the $(echo | awk) assignment stays on
  # one line and satisfies the UNSAFE_PIPE_IN_CMDSUB lint rule (which checks the
  # next line for || true; a multi-line awk body fools it into thinking || true
  # is missing even when it appears at the close of the heredoc).
  #
  # Emit ALL production lib files with any deletions (not just those above the
  # absolute threshold), so that the ratio check below can use the same
  # diff-counted deletion values for both checks — a single source of truth.
  local _awk_prog
  _awk_prog=$(mktemp)
  cat > "$_awk_prog" <<'AWKEOF'
/^diff --git a\// {
  if (current_file != "" && deleted > 0) {
    print current_file "|" deleted
  }
  # Extract destination path by splitting on " b/" rather than using $NF.
  # $NF breaks on paths with spaces (returns only the last whitespace token).
  # split() on the literal substring " b/" correctly captures the full path,
  # including any embedded spaces, from that marker to end of line.
  n = split($0, parts, " b/")
  path = (n >= 2) ? parts[n] : ""
  current_file = (path ~ prod_re) ? path : ""
  deleted = 0
  next
}
/^rename to / {
  # For cross-directory renames the destination path may differ from the source.
  # Re-evaluate current_file against the actual destination so that a file
  # renamed OUT of lib/ is not counted and a file renamed INTO lib/ is tracked.
  dest = substr($0, 11)  # strip "rename to " prefix (10 chars + 1)
  current_file = (dest ~ prod_re) ? dest : ""
  next
}
/^-/ {
  if (current_file != "" && $0 !~ /^--- /) deleted++
  next
}
END {
  if (current_file != "" && deleted > 0) {
    print current_file "|" deleted
  }
}
AWKEOF

  local _all_lib_deletions
  _all_lib_deletions=$(echo "$diff_text" | awk -v prod_re="$prod_path_re" -f "$_awk_prog" || true)
  rm -f "$_awk_prog"

  # Single pass: evaluate both the absolute threshold and the ratio threshold
  # against the same diff-counted deletion values.  This eliminates the separate
  # gh-API call that previously used .deletions (a different counter), and
  # prevents the same file from appearing twice with conflicting counts.
  local all_violations=""
  if [ -n "$_all_lib_deletions" ]; then
    while IFS='|' read -r filepath deletions; do
      [ -z "$filepath" ] && continue
      deletions="${deletions:-0}"

      # Absolute threshold check
      if [ "$deletions" -gt "$abs_lines" ]; then
        all_violations="${all_violations}${filepath}|${deletions}|${deletions}|ABS"$'\n'
        continue  # ABS already fires; skip ratio check for this file (no duplicate row)
      fi

      # Skip files with trivial deletions before the more expensive ratio check
      if [ "$deletions" -le 10 ]; then
        continue
      fi

      # Get total line count from the PR's base branch (pre-deletion baseline).
      # The worktree copy already has lines removed, so wc -l on the local file
      # would under-count the denominator and produce ratios above 100%.
      # Use -C so the call works regardless of cwd (blocker-rules.sh may be
      # invoked from within a worktree subdirectory, not the project root).
      # git show exits non-zero if the ref is unfetched or the file is new; skip.
      # base_branch was resolved from the PR earlier in this function so non-main
      # base PRs get the correct baseline (not always origin/main).
      local total_lines=0
      total_lines=$(git -C "${RITE_PROJECT_ROOT:-.}" show "origin/${base_branch}:${filepath}" 2>/dev/null | wc -l || true)
      total_lines="${total_lines:-0}"

      if [ "$total_lines" -le 0 ]; then
        # Cannot compute ratio — baseline unavailable (new file or unfetched ref).
        # Emit a [diag] warning so the skip is observable in the health report
        # and in operator logs. The absolute threshold still applies above.
        echo "[diag] SHRINKAGE_RATIO_SKIP pr=$pr_number file=$filepath base_branch=$base_branch reason=baseline_unavailable deleted=$deletions" >> "${RITE_LOG_FILE:-/dev/null}" 2>/dev/null || true
        print_warning "lib/ shrinkage: ratio check skipped for $filepath — could not fetch origin/${base_branch} baseline (deleted=$deletions lines)" >&2
        continue
      fi

      # Ratio check: deletions / total_lines > ratio_pct / 100
      # Using integer arithmetic: deletions * 100 > total_lines * ratio_pct
      local deleted_pct=$(( deletions * 100 ))
      local threshold_pct=$(( total_lines * ratio_pct ))
      if [ "$deleted_pct" -gt "$threshold_pct" ]; then
        all_violations="${all_violations}${filepath}|${deletions}|${total_lines}|RATIO"$'\n'
      fi
    done <<< "$_all_lib_deletions"
  fi

  all_violations=$(echo "$all_violations" | sed '/^$/d' || true)

  if [ -z "$all_violations" ]; then
    return 0  # No violations — clear to merge
  fi

  # Report the first violation (worst case) and collect all violating file paths.
  # head -1 exits 0 even on empty input; || true guards against any pipeline exit
  local first
  first=$(echo "$all_violations" | head -1 || true)
  local viol_file viol_deleted viol_total viol_type
  IFS='|' read -r viol_file viol_deleted viol_total viol_type <<< "$first"

  export SHRINKAGE_BLOCKER_FILE="$viol_file"
  export SHRINKAGE_BLOCKER_DELETED="$viol_deleted"
  export SHRINKAGE_BLOCKER_TOTAL="$viol_total"

  # Export all violating file paths (newline-separated) so handle_blocker can
  # generate a revert command for every affected file — not just the first.
  # A multi-file deletion PR with only the first file exported yields incomplete
  # remediation guidance and forces an extra fix cycle (issue #357).
  local _all_viol_files
  _all_viol_files=$(echo "$all_violations" | while IFS='|' read -r vf vd vt vtype; do
    [ -n "$vf" ] && echo "$vf"
  done || true)
  export SHRINKAGE_BLOCKER_FILES="$_all_viol_files"

  # Build human-readable message
  echo "BLOCKER: Large deletion detected in production lib/ file"
  echo ""
  echo "Threshold: >${ratio_pct}% of file OR >${abs_lines} lines deleted from lib/core|utils|providers"
  echo ""
  echo "Violations:"
  while IFS='|' read -r vf vd vt vtype; do
    [ -z "$vf" ] && continue
    if [ "$vtype" = "ABS" ]; then
      echo "  ${vf}: -${vd} lines (absolute threshold: >${abs_lines})"
    else
      if [ "$vt" -gt 0 ]; then
        local pct=$(( vd * 100 / vt ))
        echo "  ${vf}: -${vd} lines of ${vt} total (${pct}% deleted; threshold: >${ratio_pct}%)"
      else
        echo "  ${vf}: -${vd} lines deleted (ratio threshold: >${ratio_pct}%)"
      fi
    fi
  done <<< "$all_violations"
  echo ""
  echo "This pattern matches the 2026-06-02 incident where a buggy test overwrote"
  echo "1,256 lines of production code (lib/core/assess-review-issues.sh, lib/utils/format-review.sh)."
  echo "A human must confirm this deletion is intentional before merging."
  echo ""
  echo "To bypass (requires explicit acknowledgment):"
  echo "  RITE_SHRINKAGE_RATIO_PCT=100 rite <issue> --supervised"
  echo "  # or: rite <issue> --bypass-blockers  (unsupervised, logs to health report)"

  # Log structured diagnostic line for health report aggregation
  local log_file="${RITE_LOG_FILE:-/tmp/rite-workflow.log}"
  echo "[diag] SHRINKAGE_BLOCKER pr=$pr_number file=$viol_file deleted=$viol_deleted total=$viol_total type=$viol_type threshold_ratio=$ratio_pct threshold_abs=$abs_lines base_branch=$base_branch" >> "$log_file" 2>/dev/null || true

  return 1
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

  # lib/ shrinkage early warning: surface files that exceed the same thresholds
  # the hard pre-merge gate uses — keeping hint and gate semantically aligned.
  # Using the API .deletions field here is intentional (fast, no diff parsing at
  # PR-creation time); the hard gate re-counts from the diff for accuracy.
  local _shrinkage_ratio_pct="${RITE_SHRINKAGE_RATIO_PCT:-50}"
  local _shrinkage_abs="${RITE_SHRINKAGE_ABS_LINES:-500}"
  local _shrinkage_re="^(lib/core|lib/utils|lib/providers)/"
  local _shrinkage_matches
  _shrinkage_matches=$(echo "$changed_files" | grep -E "$_shrinkage_re" || true)
  if [ -n "$_shrinkage_matches" ]; then
    # Surface files whose deletion count exceeds the absolute gate threshold.
    # The ratio threshold requires per-file line counts (expensive at hint time),
    # so we use the same abs threshold as a consistent lower bound — any file
    # that clears abs will very likely trigger the gate.  Note: the hint reads
    # the API .deletions field while the hard gate counts ^- lines from the diff;
    # these counters can diverge slightly, so the hint is an early signal rather
    # than a guaranteed gate trigger.
    local _lib_file_deletions
    _lib_file_deletions=$(gh_safe pr view "$pr_number" --json files \
      --jq ".files[] | select(.path | test(\"${_shrinkage_re}\")) | select(.deletions > ${_shrinkage_abs}) | \"\(.path)|-\(.deletions) lines\"" \
      2>/dev/null || true)
    if [ -n "$_lib_file_deletions" ]; then
      hints+="### Sensitivity: lib/ Production Code Deletions
Files exceeding the hard merge gate threshold (>${_shrinkage_abs} lines deleted):
$(echo "$_lib_file_deletions" | sed 's/^/  /')
Guidance: Production lib/ files (lib/core/, lib/utils/, lib/providers/) will be blocked from merging if any single file loses >${_shrinkage_ratio_pct}% of its lines OR >${_shrinkage_abs} lines. Verify that deletions are intentional refactors, not accidental file overwrites. The 2026-06-02 incident deleted 1,256 lines via a buggy test writing through a symlink — this check exists to prevent a recurrence.

"
    fi
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
      local _det_checks=("critical_issues:detect_critical_issues" "lib_shrinkage:detect_lib_shrinkage")

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
    critical_issues|lib_shrinkage)
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
    lib_shrinkage|critical_issues)
      echo "false"  # Per-issue blocker — only blocks the current issue
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
  export -f detect_lib_shrinkage
  export -f detect_sensitivity_areas
  export -f check_blockers
  export -f get_blocker_urgency
  export -f is_blocking_batch
fi
