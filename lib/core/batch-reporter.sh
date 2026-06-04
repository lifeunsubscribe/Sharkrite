#!/usr/bin/env bash
# batch-reporter.sh
# Summary computation and stats-output functions for batch-process-issues.sh.
#
# Extracted into a standalone file so regression tests can source it directly
# without pulling in the full batch machinery (gh, jq, config.sh, etc.).
# batch-process-issues.sh sources this file and delegates to these functions.
#
# No external commands, no sourced dependencies — pure bash arithmetic + echo.

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f _batch_compute_totals >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# _batch_compute_totals
# Compute TOTAL_PROCESSED from the batch state arrays.
#
# TOTAL_PROCESSED = issues that actually ran through the workflow
# (completed + merged-with-cleanup-failure + failed + blocked).
# Skipped issues (waiting_for_parent, already_closed_at_start, dep_failed, etc.)
# are intentionally excluded — they never entered an active dev session.
#
# Reads:  COMPLETED_ISSUES, MERGED_CLEANUP_FAILED, FAILED_ISSUES, BLOCKED_ISSUES
# Writes: TOTAL_PROCESSED (also exported)
# ---------------------------------------------------------------------------
_batch_compute_totals() {
  TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#MERGED_CLEANUP_FAILED[@]} + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))
  export TOTAL_PROCESSED
}

# ---------------------------------------------------------------------------
# _batch_print_stats
# Emit the "Overall Statistics" block, the "Already Closed at Start" detail
# section, and the generic "Skipped Issues" detail section to stdout.
#
# Reads:  TOTAL_ISSUES, TOTAL_PROCESSED, COMPLETED_ISSUES, MERGED_CLEANUP_FAILED,
#         FAILED_ISSUES, BLOCKED_ISSUES, SKIPPED_ISSUES, ISSUE_STATUS,
#         ALREADY_CLOSED_AT_START_ISSUES (optional, defaults to empty),
#         TOTAL_DURATION (optional)
# ---------------------------------------------------------------------------
_batch_print_stats() {
  local _cleanup_warning_count=${#MERGED_CLEANUP_FAILED[@]}
  # ALREADY_CLOSED_AT_START_ISSUES may not be declared in older test fixtures;
  # default to 0 so callers that don't set it still work correctly.
  # Note: ${#array[@]:-0} is invalid bash — must use a conditional assignment.
  local _closed_at_start_count
  if declare -p ALREADY_CLOSED_AT_START_ISSUES >/dev/null 2>&1; then
    _closed_at_start_count=${#ALREADY_CLOSED_AT_START_ISSUES[@]}
  else
    _closed_at_start_count=0
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Overall Statistics"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Total Issues:     $TOTAL_ISSUES"
  echo "Processed:        $TOTAL_PROCESSED"
  if [ "$_cleanup_warning_count" -gt 0 ]; then
    echo "Completed:        $COMPLETED_ISSUES (${_cleanup_warning_count} with cleanup warnings)"
  else
    echo "Completed:        $COMPLETED_ISSUES"
  fi
  echo "Failed:           ${#FAILED_ISSUES[@]}"
  echo "Blocked:          ${#BLOCKED_ISSUES[@]}"
  echo "Skipped:          ${#SKIPPED_ISSUES[@]}"
  if [ -n "${TOTAL_DURATION:-}" ]; then
    echo "Total Duration:   ${TOTAL_DURATION}s ($((TOTAL_DURATION / 60))m)"
  fi
  echo ""

  # Already-closed-at-start issues get their own section — different from other
  # skipped reasons (waiting_for_parent, dep_failed, etc.) because:
  #   - They DID run through handle_closed_issue() — full cleanup ran
  #   - No active dev session happened, so no PR stats to gather
  #   - Remediation is different (nothing to do vs. unblock dependency)
  if [ "${_closed_at_start_count:-0}" -gt 0 ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Already Closed at Start (no new work needed)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local _closed_num
    for _closed_num in "${ALREADY_CLOSED_AT_START_ISSUES[@]}"; do
      echo "  ✅ Issue #$_closed_num (closed before this session started)"
    done
    echo ""
  fi

  # Generic skipped section: excludes already_closed_at_start issues (they have
  # their own section above) — show only the remaining skip reasons.
  local _other_skipped=()
  local _skip_num _skip_reason
  for _skip_num in "${SKIPPED_ISSUES[@]}"; do
    _skip_reason=${ISSUE_STATUS[$_skip_num]:-"unknown"}
    if [ "$_skip_reason" != "already_closed_at_start" ]; then
      _other_skipped+=("$_skip_num")
    fi
  done

  if [ ${#_other_skipped[@]} -gt 0 ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Skipped Issues"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for _skip_num in "${_other_skipped[@]}"; do
      _skip_reason=${ISSUE_STATUS[$_skip_num]:-"unknown"}
      echo "  ⏭️  Issue #$_skip_num ($_skip_reason)"
    done
    echo ""
  fi
}
