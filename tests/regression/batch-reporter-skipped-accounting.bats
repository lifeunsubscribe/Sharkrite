#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# Regression test for: Batch reporter must count all skipped issues in Skipped tally
# Issue #138 (sibling to #57 which fixed merge-vs-cleanup accounting)
#
# Bug: batch reporter under-counts skipped issues when the skip reason is
# `waiting_for_parent` (parent PR deferral) — and potentially other skip reasons
# that don't fire the "Processing Issue #N" banner first.
#
# Example of broken output:
#   Total Issues:  5    <- correct
#   Processed:     4    <- correct (4 actually ran through the workflow)
#   Failed:        0    <- correct
#   Skipped:       0    <- WRONG: should be 1 (issue #105 was parent-deferred)
#
# Expected behavior after fix:
# - Every continue path appends to SKIPPED_ISSUES and sets ISSUE_STATUS
# - Summary shows Skipped = ${#SKIPPED_ISSUES[@]}
# - Skipped Issues section lists each issue with its reason
#
# Test strategy: source lib/core/batch-reporter.sh (no external deps) and
# call _batch_compute_totals / _batch_print_stats directly.  Assertions bind
# to the real production formula — not an inlined copy — so a regression in
# batch-reporter.sh will cause these tests to fail.

# Absolute path to the repo root (two levels up from tests/regression/)
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_REPORTER="$REPO_ROOT/lib/core/batch-reporter.sh"

setup() {
  # Verify the production file exists before any test runs
  [ -f "$BATCH_REPORTER" ] || {
    echo "FATAL: $BATCH_REPORTER not found" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Helper: load batch-reporter.sh into the current subshell and set up the
# minimal state arrays that both functions require.
# Called inside run bash -c '...' blocks to keep each test isolated.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Unit: _batch_compute_totals produces the correct TOTAL_PROCESSED
# ---------------------------------------------------------------------------

@test "_batch_compute_totals: 1 completed, 2 skipped → TOTAL_PROCESSED=1" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(101 105)
    ISSUE_STATUS[101]='already_closed'
    ISSUE_STATUS[105]='waiting_for_parent'

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
    echo \"SKIPPED_COUNT=\${#SKIPPED_ISSUES[@]}\"
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TOTAL_PROCESSED=1"
  echo "$output" | grep -q "SKIPPED_COUNT=2"
}

@test "_batch_compute_totals: 0 completed, 0 skipped → TOTAL_PROCESSED=0" {
  run bash -c "
    source '${BATCH_REPORTER}'

    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TOTAL_PROCESSED=0"
}

@test "_batch_compute_totals: failed and blocked issues count toward TOTAL_PROCESSED" {
  run bash -c "
    source '${BATCH_REPORTER}'

    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=(200)
    FAILED_ISSUES=(201)
    BLOCKED_ISSUES=(202 203)
    SKIPPED_ISSUES=(101)   # must NOT be added

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
  "

  [ "$status" -eq 0 ]
  # 1 + 1 + 1 + 2 = 5
  echo "$output" | grep -q "TOTAL_PROCESSED=5"
}

# ---------------------------------------------------------------------------
# Unit: _batch_print_stats emits correct summary lines
# ---------------------------------------------------------------------------

@test "_batch_print_stats: Skipped count line reflects SKIPPED_ISSUES array length" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(101 105)
    ISSUE_STATUS[101]='already_closed'
    ISSUE_STATUS[105]='waiting_for_parent'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Total Issues:.*3"
  echo "$output" | grep -q "Processed:.*1"
  echo "$output" | grep -q "Completed:.*1"
  echo "$output" | grep -q "Failed:.*0"
  echo "$output" | grep -q "Skipped:.*2"
}

@test "_batch_print_stats: Skipped Issues section lists each issue with its reason" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(101 105)
    ISSUE_STATUS[101]='already_closed'
    ISSUE_STATUS[105]='waiting_for_parent'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Skipped Issues"
  echo "$output" | grep -q "Issue #101.*already_closed"
  echo "$output" | grep -q "Issue #105.*waiting_for_parent"
}

@test "_batch_print_stats: no Skipped Issues section when SKIPPED_ISSUES is empty" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Skipped:.*0"
  ! echo "$output" | grep -q "Skipped Issues"
}

# ---------------------------------------------------------------------------
# Integration fixture: batch of 3 issues (1 normal + 1 already-closed + 1
# parent-deferred).  Asserts Total=3, Processed=1, Skipped=2 using the real
# production functions from batch-reporter.sh — not an inlined copy.
# ---------------------------------------------------------------------------

@test "batch with one normal, one already-closed, one parent-deferred: Total=3 Processed=1 Skipped=2" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    declare -A ISSUE_TIME
    declare -A ISSUE_PR
    ISSUE_LIST=(87 101 105)
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()

    # Issue #87: normal — completes successfully
    COMPLETED_ISSUES=\$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS[87]='completed'
    ISSUE_TIME[87]=45
    ISSUE_PR[87]=201

    # Issue #101: already closed — skip
    SKIPPED_ISSUES+=(101)
    ISSUE_STATUS[101]='already_closed'

    # Issue #105: follow-up with parent PR still open, not in queue — defer
    SKIPPED_ISSUES+=(105)
    ISSUE_STATUS[105]='waiting_for_parent'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  # Statistics assertions — bound to real _batch_compute_totals formula
  echo "$output" | grep -q "Total Issues:.*3"
  echo "$output" | grep -q "Processed:.*1"
  echo "$output" | grep -q "Completed:.*1"
  echo "$output" | grep -q "Failed:.*0"
  echo "$output" | grep -q "Blocked:.*0"
  echo "$output" | grep -q "Skipped:.*2"

  # Skipped detail — bound to real _batch_print_stats output
  echo "$output" | grep -q "Skipped Issues"
  echo "$output" | grep -q "Issue #101.*already_closed"
  echo "$output" | grep -q "Issue #105.*waiting_for_parent"
}

@test "TOTAL_PROCESSED excludes skipped issues: skipped does not inflate processed count" {
  # Regression guard: TOTAL_PROCESSED must NOT include SKIPPED_ISSUES.
  # Uses _batch_compute_totals from production code directly.
  run bash -c "
    source '${BATCH_REPORTER}'

    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(101 105)  # 2 skipped — must NOT appear in TOTAL_PROCESSED

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
    echo \"SKIPPED_COUNT=\${#SKIPPED_ISSUES[@]}\"
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TOTAL_PROCESSED=1"
  echo "$output" | grep -q "SKIPPED_COUNT=2"
}
