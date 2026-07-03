#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/claude-workflow.sh, lib/core/workflow-runner.sh, lib/core/batch-reporter.sh
# tests/regression/batch-locked-issue-in-progress-status.bats
#
# Regression test: a batch issue whose lock is held by another live rite session
# must be reported as "in_progress_elsewhere" (SKIPPED class), NOT as failed.
#
# Issue #797 — "Issue locked mislabeled as failed in batch"
#
# Bug: acquire_issue_lock() prints "❌ Issue #N is already being processed by PID X"
# and returns 1. claude-workflow.sh did a bare `exit 1` on lock failure.
# batch-process-issues.sh had no case for a lock-held collision, so it fell to
# the catch-all else branch and recorded status=failed.
#
# Fix:
#   1. claude-workflow.sh emits exit 14 (not 1) on lock-held.
#   2. workflow-runner.sh propagates exit 14 unchanged.
#   3. batch-process-issues.sh maps exit 14 → in_progress_elsewhere (SKIPPED class).
#   4. batch-reporter.sh renders an "In Progress Elsewhere" section (not Failed).
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1. claude-workflow.sh: exit 14 (not 1) on lock failure
#     2. workflow-runner.sh: explicit elif for exit 14 propagation
#     3. batch-process-issues.sh: elif branch for _WF_EXIT -eq 14
#     4. batch-process-issues.sh: IN_PROGRESS_ELSEWHERE_ISSUES array initialized
#     5. batch-process-issues.sh: in_progress_elsewhere status set in exit-14 branch
#     6. batch-process-issues.sh: no gh API calls in exit-14 branch
#     7. exit-codes.md: exit 14 documented in claude-workflow.sh table
#
#   UNIT (batch-reporter.sh):
#     8. in_progress_elsewhere counts as Skipped (not Processed, not Failed)
#     9. Summary shows "In Progress Elsewhere" section with the issue
#    10. in_progress_elsewhere does NOT appear in generic Skipped Issues section
#    11. in_progress_elsewhere does NOT appear in Failed Issues
#    12. IN_PROGRESS_ELSEWHERE_ISSUES unset → backward compat (no crash)
#
#   INTEGRATION (reporter with mixed batch):
#    13. Batch of 1 active + 1 locked + 1 already-closed: correct counts
#    14. Genuine failure (exit 1) still maps to status=failed (catch-all unchanged)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLAUDE_WORKFLOW="$REPO_ROOT/lib/core/claude-workflow.sh"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
BATCH_REPORTER="$REPO_ROOT/lib/core/batch-reporter.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"

setup() {
  [ -f "$CLAUDE_WORKFLOW" ] || {
    echo "FATAL: $CLAUDE_WORKFLOW not found" >&2
    return 1
  }
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$BATCH_REPORTER" ] || {
    echo "FATAL: $BATCH_REPORTER not found" >&2
    return 1
  }
  [ -f "$EXIT_CODES_DOC" ] || {
    echo "FATAL: $EXIT_CODES_DOC not found" >&2
    return 1
  }
}

teardown() {
  # Temp-dir cleanup for the exit-14 integration test. This MUST live in
  # teardown(), never as a `trap ... EXIT` inside a @test body: bats emits the
  # test's result from its own EXIT trap in the same shell, so a trap inside a
  # test clobbers it — the whole file then reports "Executed 0 instead of
  # expected N" and writes NOTHING to report.tap, giving the gate a blocking
  # failure with zero nameable findings (issue #804, PR #828's blind rounds).
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify the fix is in place (static code inspection)
# =============================================================================

@test "structural: claude-workflow.sh exits 14 (not 1) on lock acquisition failure" {
  # The fix: setup_issue_lock_if_needed must exit 14 when acquire_issue_lock fails,
  # not exit 1 (which is indistinguishable from a real dev failure).
  _func_body=$(awk '
    /^setup_issue_lock_if_needed[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$CLAUDE_WORKFLOW")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract setup_issue_lock_if_needed function body" >&2
    return 1
  }

  # Must contain exit 14
  echo "$_func_body" | grep -qE 'exit 14' || {
    echo "FAIL: setup_issue_lock_if_needed does not contain 'exit 14'" >&2
    echo "      The distinct lock-held code is required so batch can classify it correctly" >&2
    return 1
  }

  # Must NOT have a bare `exit 1` in the lock-failure branch (the `if ! acquire_issue_lock` block)
  # Extract the if-not-acquire block
  _lock_block=$(echo "$_func_body" | awk '
    /if ! acquire_issue_lock/ { in_block=1; next }
    in_block && /^[[:space:]]*fi$/ { exit }
    in_block { print $0 }
  ')
  if echo "$_lock_block" | grep -qE '^\s*exit 1$'; then
    echo "FAIL: bare 'exit 1' found in the lock-failure block of setup_issue_lock_if_needed" >&2
    echo "      Should be 'exit 14' to distinguish lock-held from a real dev failure" >&2
    return 1
  fi
}

@test "structural: workflow-runner.sh has explicit elif for exit 14 propagation" {
  # The main() top-level executor must have an elif branch for exit 14 so it
  # propagates the sentinel to batch instead of converting it to exit 1 via else.
  grep -qE 'elif \[ \$workflow_exit -eq 14 \]' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'elif [ \$workflow_exit -eq 14 ]' branch in workflow-runner.sh" >&2
    echo "      Without this, exit 14 falls to the else branch → exit 1 (mislabeled as failure)" >&2
    return 1
  }

  # The branch must emit 'exit 14'
  grep -qE 'exit 14' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'exit 14' in workflow-runner.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has elif branch for _WF_EXIT -eq 14" {
  grep -qE 'elif \[ \$_WF_EXIT -eq 14 \]' "$BATCH_PROCESSOR" || {
    echo "FAIL: No 'elif [ \$_WF_EXIT -eq 14 ]' branch in batch-process-issues.sh" >&2
    echo "      Exit 14 must route to the in_progress_elsewhere skip path" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has IN_PROGRESS_ELSEWHERE_ISSUES array" {
  grep -q 'IN_PROGRESS_ELSEWHERE_ISSUES=' "$BATCH_PROCESSOR" || {
    echo "FAIL: IN_PROGRESS_ELSEWHERE_ISSUES array not initialized in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh sets in_progress_elsewhere status in exit-14 branch" {
  # Extract the exit-14 branch body
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 14 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract the exit-14 branch body from batch-process-issues.sh" >&2
    return 1
  }

  echo "$_branch_body" | grep -q 'in_progress_elsewhere' || {
    echo "FAIL: 'in_progress_elsewhere' status not set in exit-14 branch" >&2
    return 1
  }

  echo "$_branch_body" | grep -q 'IN_PROGRESS_ELSEWHERE_ISSUES+=' || {
    echo "FAIL: IN_PROGRESS_ELSEWHERE_ISSUES not appended in exit-14 branch" >&2
    return 1
  }

  echo "$_branch_body" | grep -q 'SKIPPED_ISSUES+=' || {
    echo "FAIL: SKIPPED_ISSUES not appended in exit-14 branch (must count toward Skipped)" >&2
    return 1
  }
}

@test "structural: no gh API calls in exit-14 branch (non-comment lines only)" {
  # The exit-14 branch must not fire any gh pr list / gh pr view / gh issue list —
  # no dev session ran, so stat-gathering is meaningless and the API calls are wasted.
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 14 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract the exit-14 branch body" >&2
    return 1
  }

  _noncomment_body=$(echo "$_branch_body" | grep -v '^\s*#')

  if echo "$_noncomment_body" | grep -qE 'gh.*pr list'; then
    echo "FAIL: 'gh pr list' (non-comment) found in exit-14 branch" >&2
    return 1
  fi

  if echo "$_noncomment_body" | grep -qE 'gh.*pr view'; then
    echo "FAIL: 'gh pr view' (non-comment) found in exit-14 branch" >&2
    return 1
  fi

  if echo "$_noncomment_body" | grep -qE 'gh.*issue list'; then
    echo "FAIL: 'gh issue list' (non-comment) found in exit-14 branch" >&2
    return 1
  fi
}

@test "structural: exit-codes.md documents exit 14 for claude-workflow.sh" {
  grep -q '14' "$EXIT_CODES_DOC" || {
    echo "FAIL: exit code 14 not mentioned in docs/architecture/exit-codes.md" >&2
    return 1
  }

  # Specifically in the claude-workflow.sh section
  _cw_section=$(awk '
    /^### `claude-workflow.sh`$/ { in_section=1; next }
    in_section && /^###/ { exit }
    in_section { print $0 }
  ' "$EXIT_CODES_DOC")

  echo "$_cw_section" | grep -q '14' || {
    echo "FAIL: exit 14 not documented in the claude-workflow.sh section of exit-codes.md" >&2
    return 1
  }
}

# =============================================================================
# UNIT: batch-reporter.sh handles in_progress_elsewhere correctly
# =============================================================================

@test "reporter: in_progress_elsewhere counts as Skipped (not Processed or Failed)" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(38)
    IN_PROGRESS_ELSEWHERE_ISSUES=(38)
    ISSUE_STATUS[38]='in_progress_elsewhere'

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
    _batch_print_stats | grep 'Skipped:'
  "

  [ "$status" -eq 0 ]
  # TOTAL_PROCESSED = completed(1) only — the locked issue is excluded
  echo "$output" | grep -q "TOTAL_PROCESSED=1"
  # Skipped count includes the in_progress_elsewhere issue
  echo "$output" | grep -q "Skipped:.*1"
}

@test "reporter: in_progress_elsewhere shows 'In Progress Elsewhere' section" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(38)
    IN_PROGRESS_ELSEWHERE_ISSUES=(38)
    ISSUE_STATUS[38]='in_progress_elsewhere'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  # Distinct section header must be present
  echo "$output" | grep -q "In Progress Elsewhere"
  # Issue must appear in that section
  echo "$output" | grep -q "Issue #38"
  # The issue entry must mention the reason (not just the number)
  echo "$output" | grep -q "38.*another session"
}

@test "reporter: in_progress_elsewhere does NOT appear in generic Skipped Issues section" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(38 105)
    IN_PROGRESS_ELSEWHERE_ISSUES=(38)
    ISSUE_STATUS[38]='in_progress_elsewhere'
    ISSUE_STATUS[105]='waiting_for_parent'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  # Issue #105 (waiting_for_parent) must appear in generic Skipped Issues section
  echo "$output" | grep -q "Issue #105"

  # Extract only the lines in the generic Skipped Issues section
  _skipped_lines=$(echo "$output" | awk '/^Skipped Issues$/{found=1; next} found && /^━/{exit} found{print}')
  # The generic section must NOT contain in_progress_elsewhere
  if [ -n "$_skipped_lines" ]; then
    if echo "$_skipped_lines" | grep -q 'in_progress_elsewhere'; then
      echo 'FAIL: in_progress_elsewhere reason appeared in generic Skipped Issues section' >&2
      return 1
    fi
  fi
}

@test "reporter: in_progress_elsewhere does NOT appear in Failed Issues" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(38)
    IN_PROGRESS_ELSEWHERE_ISSUES=(38)
    ISSUE_STATUS[38]='in_progress_elsewhere'

    _batch_compute_totals
    _batch_print_stats
    echo \"FAILED_COUNT=\${#FAILED_ISSUES[@]}\"
  "

  [ "$status" -eq 0 ]
  # Failed count must be 0
  echo "$output" | grep -q "Failed:.*0"
  echo "$output" | grep -q "FAILED_COUNT=0"
}

@test "reporter: backward compat — works when IN_PROGRESS_ELSEWHERE_ISSUES is not set" {
  # Old test fixtures that don't declare IN_PROGRESS_ELSEWHERE_ISSUES must still work.
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(105)
    ISSUE_STATUS[105]='waiting_for_parent'
    # IN_PROGRESS_ELSEWHERE_ISSUES intentionally not set

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  # Must not crash; no 'In Progress Elsewhere' section when array is absent
  ! echo "$output" | grep -q "In Progress Elsewhere"
  echo "$output" | grep -q "Skipped:.*1"
}

@test "reporter: no 'In Progress Elsewhere' section when IN_PROGRESS_ELSEWHERE_ISSUES is empty" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "In Progress Elsewhere"
}

# =============================================================================
# INTEGRATION: batch summary with mixed issue types
# =============================================================================

@test "integration: batch with 1 active + 1 locked + 1 already-closed — correct counts" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    declare -A ISSUE_TIME
    declare -A ISSUE_PR
    ISSUE_LIST=(40 38 99)
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    ALREADY_CLOSED_AT_START_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()

    # Issue #40: active completion
    COMPLETED_ISSUES=\$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS[40]='completed'
    ISSUE_TIME[40]=180
    ISSUE_PR[40]=301

    # Issue #38: lock held by another live session — exit 14 path
    SKIPPED_ISSUES+=(38)
    IN_PROGRESS_ELSEWHERE_ISSUES+=(38)
    ISSUE_STATUS[38]='in_progress_elsewhere'
    ISSUE_TIME[38]=1

    # Issue #99: already closed when batch started — exit 12 path
    SKIPPED_ISSUES+=(99)
    ALREADY_CLOSED_AT_START_ISSUES+=(99)
    ISSUE_STATUS[99]='already_closed_at_start'
    ISSUE_TIME[99]=1

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  # Overall stats
  echo "$output" | grep -q "Total Issues:.*3"
  echo "$output" | grep -q "Processed:.*1"
  echo "$output" | grep -q "Completed:.*1"
  echo "$output" | grep -q "Failed:.*0"
  echo "$output" | grep -q "Blocked:.*0"
  echo "$output" | grep -q "Skipped:.*2"

  # In Progress Elsewhere section for #38
  echo "$output" | grep -q "In Progress Elsewhere"
  echo "$output" | grep -q "Issue #38"

  # Already Closed section for #99
  echo "$output" | grep -q "Already Closed at Start"
  echo "$output" | grep -q "Issue #99"

  # Generic Skipped Issues section must NOT appear
  ! echo "$output" | grep -q "^Skipped Issues"
}

@test "integration: genuine failure (exit 1) still maps to status=failed" {
  # The catch-all else branch must be unchanged — a real dev failure must still
  # appear in FAILED_ISSUES, not be misclassified as in_progress_elsewhere.
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=(77)
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()
    ISSUE_STATUS[77]='failed'

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
    _batch_print_stats | grep 'Failed:'
  "

  [ "$status" -eq 0 ]
  # Failed count must reflect the real failure
  echo "$output" | grep -q "Failed:.*1"
  # TOTAL_PROCESSED counts the failure (it entered the workflow)
  echo "$output" | grep -q "TOTAL_PROCESSED=2"
}

# =============================================================================
# INTEGRATION: exit-14 propagation through run_workflow (producer-side)
# =============================================================================

@test "integration: run_workflow returns 14 when phase_claude_workflow returns 14" {
  # Verify that exit 14 produced by phase_claude_workflow (lock-held scenario)
  # is preserved by run_workflow's phase-1 dispatch — not collapsed to exit 1.
  #
  # This test exercises the real run_workflow code path with minimal stubs:
  # - gh_safe is overridden to return an OPEN issue (so the closed-issue check passes)
  # - phase_pre_start_checks is overridden to return 0 (skip credential/session checks)
  # - phase_claude_workflow is overridden to return 14 (simulate lock-held)
  # All other phases are never reached, so no additional stubs are needed.
  #
  # Before the fix in PR #797, run_workflow did:
  #   if ! phase_claude_workflow "$issue_number"; then return 1; fi
  # which collapsed return 14 to return 1, making the exit-14 branch in main()
  # unreachable.  After the fix the return code is forwarded as-is (14).

  _RUNNER="${REPO_ROOT}/lib/core/workflow-runner.sh"
  [ -f "$_RUNNER" ] || {
    echo "FATAL: $_RUNNER not found" >&2
    return 1
  }

  # Build the harness script in a temp dir to avoid any working-dir coupling.
  # Cleaned up in teardown() — never trap EXIT inside a @test body (see the
  # teardown() comment: it clobbers bats' result-emitting EXIT trap).
  _tmpdir=$(mktemp -d)

  cat > "$_tmpdir/harness.sh" <<'HARNESS_EOF'
#!/bin/bash
# Minimal harness to verify exit-14 propagation through run_workflow.
# Stubs are defined before sourcing workflow-runner.sh.
# After source, overrides replace the real phase functions.

set -uo pipefail
# Note: not -e here so we can capture non-zero returns from run_workflow.

RITE_LIB_DIR="${1:?RITE_LIB_DIR required}"
export RITE_LIB_DIR

# ── Minimal stubs for workflow-runner.sh's source-time dependencies ──

# Stub out config.sh by pre-setting RITE_LIB_DIR so its guard fires.
# Also set variables that config.sh would normally set.
export RITE_PROJECT_ROOT="${TMPDIR:-/tmp}/rw-exit14-test-$$"
export RITE_DATA_DIR=".rite"
export RITE_LOCK_DIR="${RITE_PROJECT_ROOT}/.rite/locks"
export RITE_STATE_DIR="${RITE_PROJECT_ROOT}/.rite/state"
export RITE_LOG_FILE="/dev/null"
export WORKFLOW_MODE="unsupervised"
export RESUME_MODE=false
export BATCH_MODE=false
export SESSION_STATE_FILE="/dev/null"
export CLOSING_ISSUE_JQ_REGEX="Closes "
export RITE_MARKER_REVIEW="sharkrite-local-review"
export RITE_MARKER_ASSESSMENT="sharkrite-assessment"
export RITE_MARKER_FOLLOWUP="sharkrite-followup"
export NORMALIZED_SUBJECT="test issue"
export WORK_DESCRIPTION="test"
export ISSUE_BODY=""

# gh_safe stub: return OPEN issue, empty PR list
gh_safe() {
  case "${1:-}" in
    issue)
      # gh_safe issue view N --json state,...
      echo '{"state":"OPEN","title":"Test issue","closedAt":null,"closedByPullRequestsReferences":[]}'
      ;;
    pr)
      # gh_safe pr list ... → empty, so PR_NUMBER stays unset
      echo '[]'
      ;;
    *)
      echo '{}' ;;
  esac
}
export -f gh_safe

# Stub out functions called at source time or early in run_workflow
normalize_existing_issue() { :; }
export -f normalize_existing_issue

set_current_worktree() { :; }
export -f set_current_worktree

set_current_issue() { :; }
export -f set_current_issue

_diag() { :; }
export -f _diag

_rtk_snapshot() { :; }
export -f _rtk_snapshot

_timer_start() { :; }
export -f _timer_start

_timer_end() { :; }
export -f _timer_end

# ── Source workflow-runner.sh to get run_workflow() definition ──
# The BASH_SOURCE guard ensures main() does NOT execute on source.
# The _RITE_WORKFLOW_RUNNER_LOADED guard makes it idempotent.
source "${RITE_LIB_DIR}/core/workflow-runner.sh" 2>/dev/null || true

# ── Override phase functions after source (so our stubs win) ──

# phase_pre_start_checks: skip credential/session checks
phase_pre_start_checks() { return 0; }

# phase_claude_workflow: simulate lock-held — exit 14
phase_claude_workflow() { return 14; }

# ── Exercise run_workflow and capture its return code ──
_exit=0
run_workflow 797 >/dev/null 2>&1 || _exit=$?
echo "RW_EXIT=${_exit}"
HARNESS_EOF

  chmod +x "$_tmpdir/harness.sh"

  # Run the harness; pass RITE_LIB_DIR as argument
  run bash "$_tmpdir/harness.sh" "${REPO_ROOT}/lib"

  # The harness must complete without a script-level crash
  # (set -u with unbound vars would cause exit 1 before the echo; exit 2 = nounset)
  echo "$output" | grep -q "RW_EXIT=" || {
    echo "FAIL: harness did not emit RW_EXIT — likely crashed during setup" >&2
    echo "harness output:" >&2
    echo "$output" >&2
    return 1
  }

  # Extract the captured exit code
  _rw_exit=$(echo "$output" | grep "^RW_EXIT=" | cut -d= -f2)

  [ "$_rw_exit" = "14" ] || {
    echo "FAIL: run_workflow returned ${_rw_exit}, expected 14" >&2
    echo "      This means phase_claude_workflow's return 14 was collapsed to ${_rw_exit}." >&2
    echo "      Check the 'if ! phase_claude_workflow' → 'return 1' pattern in run_workflow." >&2
    return 1
  }
}

@test "behavioral: exit-14 branch does not add to FAILED_ISSUES" {
  # Structural: search for any FAILED_ISSUES+= in the exit-14 branch.
  # No failed assignment must appear there.
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 14 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "${BATCH_PROCESSOR}")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract exit-14 branch" >&2
    return 1
  }

  if echo "$_branch_body" | grep -qE 'FAILED_ISSUES\+='; then
    echo "FAIL: FAILED_ISSUES+= found in exit-14 branch — locked issues must not be counted as failures" >&2
    return 1
  fi
}
