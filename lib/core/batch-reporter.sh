#!/usr/bin/env bash
# batch-reporter.sh
# Summary computation and stats-output functions for batch-process-issues.sh.
#
# Extracted into a standalone file so regression tests can source it directly
# without pulling in the full batch machinery (gh, jq, config.sh, etc.).
# batch-process-issues.sh sources this file and delegates to these functions.
#
# No external commands, no sourced dependencies — pure bash arithmetic + echo.

set -euo pipefail

# Re-source guard: skip if already loaded (_batch_compute_totals is the canonical indicator)
if declare -f _batch_compute_totals >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# _batch_compute_totals
# Compute TOTAL_PROCESSED from the batch state arrays.
#
# TOTAL_PROCESSED = issues that actually ran through the workflow
# (completed + merged-with-cleanup-failure + failed + blocked).
# Skipped issues (waiting_for_parent, already_closed, dep_failed, etc.)
# are intentionally excluded — they never entered the workflow.
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
# Emit the "Overall Statistics" block and the "Skipped Issues" detail section
# to stdout.
#
# Reads:  TOTAL_ISSUES, TOTAL_PROCESSED, COMPLETED_ISSUES, MERGED_CLEANUP_FAILED,
#         FAILED_ISSUES, BLOCKED_ISSUES, SKIPPED_ISSUES, ISSUE_STATUS,
#         TOTAL_DURATION (optional)
# ---------------------------------------------------------------------------
_batch_print_stats() {
  local _cleanup_warning_count=${#MERGED_CLEANUP_FAILED[@]}

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

  if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Skipped Issues"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local _skip_num _skip_reason
    for _skip_num in "${SKIPPED_ISSUES[@]}"; do
      _skip_reason=${ISSUE_STATUS[$_skip_num]:-"unknown"}
      echo "  ⏭️  Issue #$_skip_num ($_skip_reason)"
    done
    echo ""
  fi
}
