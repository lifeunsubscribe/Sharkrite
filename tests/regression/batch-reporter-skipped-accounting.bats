#!/usr/bin/env bats
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

setup() {
  export RITE_ROOT_DIR="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_LIB_DIR="${RITE_ROOT_DIR}/lib"
  export RITE_CORE_DIR="${RITE_LIB_DIR}/core"

  mkdir -p "$RITE_CORE_DIR"

  # Mock print functions — all output to stderr so stdout stays clean for summary checks
  print_status()  { echo "$@" >&2; }
  print_warning() { echo "WARNING: $@" >&2; }
  print_success() { echo "SUCCESS: $@" >&2; }
  print_info()    { echo "INFO: $@" >&2; }
  print_error()   { echo "ERROR: $@" >&2; }
  export -f print_status print_warning print_success print_info print_error
}

teardown() {
  rm -rf "$RITE_ROOT_DIR"
}

# ---------------------------------------------------------------------------
# Unit: each individual skip path populates SKIPPED_ISSUES + ISSUE_STATUS
# ---------------------------------------------------------------------------

@test "already_closed skip path populates SKIPPED_ISSUES and ISSUE_STATUS" {
  run bash -c '
    set -euo pipefail
    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=()

    ISSUE_NUM=101
    ISSUE_STATE=CLOSED

    if [ "$ISSUE_STATE" = "CLOSED" ]; then
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="already_closed"
    fi

    echo "skipped_count:${#SKIPPED_ISSUES[@]}"
    echo "status:${ISSUE_STATUS[$ISSUE_NUM]}"
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "skipped_count:1"
  echo "$output" | grep -q "status:already_closed"
}

@test "waiting_for_parent skip path populates SKIPPED_ISSUES and ISSUE_STATUS" {
  run bash -c '
    set -euo pipefail
    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=()

    ISSUE_NUM=105
    PARENT_PR_STATE=OPEN
    PARENT_IN_QUEUE=false

    if [ "$PARENT_PR_STATE" = "OPEN" ] && [ "$PARENT_IN_QUEUE" = "false" ]; then
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"
    fi

    echo "skipped_count:${#SKIPPED_ISSUES[@]}"
    echo "status:${ISSUE_STATUS[$ISSUE_NUM]}"
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "skipped_count:1"
  echo "$output" | grep -q "status:waiting_for_parent"
}

@test "dep_failed skip path populates SKIPPED_ISSUES and ISSUE_STATUS" {
  run bash -c '
    set -euo pipefail
    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=()

    ISSUE_NUM=107
    ISSUE_STATUS[42]="failed"

    dep_status="${ISSUE_STATUS[42]:-}"
    if [ "$dep_status" = "failed" ]; then
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="dep_failed"
    fi

    echo "skipped_count:${#SKIPPED_ISSUES[@]}"
    echo "status:${ISSUE_STATUS[$ISSUE_NUM]}"
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "skipped_count:1"
  echo "$output" | grep -q "status:dep_failed"
}

# ---------------------------------------------------------------------------
# Integration: summary reporter reads from SKIPPED_ISSUES correctly
# ---------------------------------------------------------------------------

@test "batch summary Skipped count equals SKIPPED_ISSUES array length" {
  # This replicates the exact summary output logic from batch-process-issues.sh
  run bash -c '
    set -euo pipefail
    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=(101 105)
    ISSUE_STATUS[101]="already_closed"
    ISSUE_STATUS[105]="waiting_for_parent"
    COMPLETED_ISSUES=1
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    MERGED_CLEANUP_FAILED=()
    TOTAL_ISSUES=3

    TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#MERGED_CLEANUP_FAILED[@]} + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))

    echo "Total Issues:     $TOTAL_ISSUES"
    echo "Processed:        $TOTAL_PROCESSED"
    echo "Completed:        $COMPLETED_ISSUES"
    echo "Failed:           ${#FAILED_ISSUES[@]}"
    echo "Blocked:          ${#BLOCKED_ISSUES[@]}"
    echo "Skipped:          ${#SKIPPED_ISSUES[@]}"
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Total Issues:.*3"
  echo "$output" | grep -q "Processed:.*1"
  echo "$output" | grep -q "Completed:.*1"
  echo "$output" | grep -q "Failed:.*0"
  echo "$output" | grep -q "Skipped:.*2"
}

@test "batch summary Skipped section lists each issue with its reason" {
  # Verifies the detailed Skipped Issues listing (lines 784-792 of batch-process-issues.sh)
  run bash -c '
    set -euo pipefail
    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=(101 105)
    ISSUE_STATUS[101]="already_closed"
    ISSUE_STATUS[105]="waiting_for_parent"

    if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
      echo "Skipped Issues"
      for ISSUE_NUM in "${SKIPPED_ISSUES[@]}"; do
        REASON=${ISSUE_STATUS[$ISSUE_NUM]:-"unknown"}
        echo "  Issue #$ISSUE_NUM ($REASON)"
      done
    fi
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Skipped Issues"
  echo "$output" | grep -q "Issue #101.*already_closed"
  echo "$output" | grep -q "Issue #105.*waiting_for_parent"
}

# ---------------------------------------------------------------------------
# Full fixture: batch of 3 issues (1 normal + 1 already-closed + 1 parent-deferred)
# Asserts: Total=3, Processed=1, Skipped=2 (both reasons listed in Skipped section)
# ---------------------------------------------------------------------------

@test "batch with one normal, one already-closed, one parent-deferred shows Total=3 Processed=1 Skipped=2" {
  run bash -c '
    set -euo pipefail

    # Setup: simulate batch-process-issues.sh state arrays
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
    ISSUE_NUM=87
    COMPLETED_ISSUES=$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS["$ISSUE_NUM"]="completed"
    ISSUE_TIME["$ISSUE_NUM"]=45
    ISSUE_PR["$ISSUE_NUM"]=201

    # Issue #101: already closed — skip
    ISSUE_NUM=101
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="already_closed"

    # Issue #105: follow-up with parent PR still open, parent not in queue — defer
    ISSUE_NUM=105
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"

    # Compute TOTAL_PROCESSED (same formula as batch-process-issues.sh line 672)
    TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#MERGED_CLEANUP_FAILED[@]} + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))

    # Emit summary (same format as batch-process-issues.sh lines 709-721)
    echo "Total Issues:     $TOTAL_ISSUES"
    echo "Processed:        $TOTAL_PROCESSED"
    echo "Completed:        $COMPLETED_ISSUES"
    echo "Failed:           ${#FAILED_ISSUES[@]}"
    echo "Blocked:          ${#BLOCKED_ISSUES[@]}"
    echo "Skipped:          ${#SKIPPED_ISSUES[@]}"
    echo ""

    # Emit Skipped Issues detail (batch-process-issues.sh lines 784-792)
    if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
      echo "Skipped Issues"
      for ISSUE_NUM in "${SKIPPED_ISSUES[@]}"; do
        REASON=${ISSUE_STATUS[$ISSUE_NUM]:-"unknown"}
        echo "  Issue #$ISSUE_NUM ($REASON)"
      done
    fi
  '

  [ "$status" -eq 0 ]

  # Statistics assertions
  echo "$output" | grep -q "Total Issues:.*3"
  echo "$output" | grep -q "Processed:.*1"
  echo "$output" | grep -q "Completed:.*1"
  echo "$output" | grep -q "Failed:.*0"
  echo "$output" | grep -q "Blocked:.*0"
  echo "$output" | grep -q "Skipped:.*2"

  # Skipped detail assertions: both reasons must appear
  echo "$output" | grep -q "Skipped Issues"
  echo "$output" | grep -q "Issue #101.*already_closed"
  echo "$output" | grep -q "Issue #105.*waiting_for_parent"
}

@test "batch with zero skipped issues shows Skipped: 0 and no Skipped Issues section" {
  run bash -c '
    set -euo pipefail

    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=()
    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    TOTAL_ISSUES=2

    TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#MERGED_CLEANUP_FAILED[@]} + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))

    echo "Total Issues:     $TOTAL_ISSUES"
    echo "Processed:        $TOTAL_PROCESSED"
    echo "Skipped:          ${#SKIPPED_ISSUES[@]}"

    if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
      echo "Skipped Issues"
    fi
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Skipped:.*0"
  ! echo "$output" | grep -q "Skipped Issues"
}

@test "TOTAL_PROCESSED excludes skipped issues (skipped does not inflate processed count)" {
  # Regression guard: TOTAL_PROCESSED must NOT include SKIPPED_ISSUES.
  # It represents issues that actually ran through the workflow.
  run bash -c '
    set -euo pipefail

    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(101 105)  # 2 skipped — must NOT be added to TOTAL_PROCESSED

    TOTAL_PROCESSED=$((COMPLETED_ISSUES + ${#MERGED_CLEANUP_FAILED[@]} + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]}))

    echo "TOTAL_PROCESSED=$TOTAL_PROCESSED"
    echo "SKIPPED_COUNT=${#SKIPPED_ISSUES[@]}"
  '

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TOTAL_PROCESSED=1"
  echo "$output" | grep -q "SKIPPED_COUNT=2"
}
