#!/usr/bin/env bats
# tests/regression/batch-closed-issue-skip-stats.bats
#
# Regression test: batch processor must NOT fire post-issue gh API calls for
# already-closed issues.
#
# Issue #316 — "Eliminate gh calls in closed-issue batch reporting"
#
# Bug: After handle_closed_issue() returned for an already-closed issue in batch
# mode, batch-process-issues.sh fired 5 sequential gh API calls to gather PR
# stats for the batch summary:
#   1. gh pr list --search (find PR by body text)       ~1-2s
#   2. gh pr view --json headRefName                    ~300ms
#   3. gh pr view --json additions,deletions,...        ~300ms
#   4. gh pr view --json files (security doc check)     ~300ms
#   5. gh issue list --label tech-debt --search         ~1-2s
#
# These calls are only meaningful after an active dev session. For an issue that
# was already closed when the batch started, no new work happened — the PR is
# historical and stats won't change.
#
# User-visible symptom: 3-30s silent hang after "Nothing to do!" message for
# each already-closed issue in a batch.
#
# Fix:
#   1. handle_closed_issue() returns exit code 12 (sentinel: "closed at start").
#   2. run_workflow() propagates exit 12 unchanged.
#   3. workflow-runner.sh's top-level executor propagates exit 12 unchanged.
#   4. batch-process-issues.sh captures the exit code BEFORE any if/then test
#      using: _WF_EXIT=0; cmd || _WF_EXIT=$?
#      Exit 12 routes to a skip path that records already_closed_at_start and
#      bypasses all post-issue gh API calls.
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1. handle_closed_issue() returns 12 (not 0)
#     2. run_workflow() propagates $? from handle_closed_issue (not return 0)
#     3. workflow-runner.sh top-level executor has explicit exit 12 case
#     4. batch-process-issues.sh captures exit code before if/then
#        (uses `|| _WF_EXIT=$?` pattern, not bare `if; then`)
#     5. batch-process-issues.sh has exit-12 branch that skips gh calls
#     6. No gh pr list, gh pr view, or gh issue list in the exit-12 branch
#
#   UNIT (batch-reporter.sh):
#     7. already_closed_at_start counts as Skipped (not Completed, not Processed)
#     8. Summary shows distinct "Already Closed at Start" section
#     9. Generic "Skipped Issues" section does NOT contain already_closed_at_start issues
#    10. TOTAL_PROCESSED excludes already_closed_at_start issues
#
#   INTEGRATION (reporter with mixed batch):
#    11. Batch of 1 active + 2 already-closed: Processed=1, Skipped=2, Completed=1
#
# Parity note: The per-issue SIDE EFFECTS (closure summary, artifact cleanup) are
# identical between single-issue and batch mode — that's the parity contract.
# The BATCH-LEVEL REPORTING LAYER is intentionally differentiated based on what
# kind of work happened. This is documented divergence, not a parity violation.
# See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity"
# See: docs/architecture/exit-codes.md — exit code 12

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
BATCH_REPORTER="$REPO_ROOT/lib/core/batch-reporter.sh"

setup() {
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
}

# =============================================================================
# STRUCTURAL: verify the fix is in place (static code inspection)
# =============================================================================

@test "structural: handle_closed_issue() returns 12, not 0" {
  # Extract handle_closed_issue function body
  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_closed_issue function body" >&2
    return 1
  }

  # Must have `return 12` somewhere in the function body
  echo "$_func_body" | grep -qE '^\s*return 12' || {
    echo "FAIL: handle_closed_issue does not contain 'return 12'" >&2
    echo "      The sentinel exit code is required so batch can skip post-issue gh calls" >&2
    return 1
  }
}

@test "structural: handle_closed_issue() does NOT have bare 'return 0' as final return" {
  # The old code had `return 0` as the last statement. After the fix, that line
  # must be replaced with `return 12`. A bare `return 0` at the end would mean
  # the sentinel never fires.
  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_closed_issue function body" >&2
    return 1
  }

  # Find the last return statement in the function
  _last_return=$(echo "$_func_body" | grep -E '^\s*[0-9]+:\s*return [0-9]+' | tail -1)
  [ -n "$_last_return" ] || {
    echo "FAIL: No return statement found in handle_closed_issue" >&2
    return 1
  }

  # The last return must NOT be `return 0`
  if echo "$_last_return" | grep -qE 'return 0$'; then
    echo "FAIL: Last return in handle_closed_issue is 'return 0' (should be 'return 12')" >&2
    echo "      Found: $_last_return" >&2
    return 1
  fi

  # And it must be return 12
  echo "$_last_return" | grep -qE 'return 12$' || {
    echo "FAIL: Last return in handle_closed_issue is not 'return 12'" >&2
    echo "      Found: $_last_return" >&2
    return 1
  }
}

@test "structural: run_workflow() propagates exit code from handle_closed_issue via 'return \$?'" {
  # The old code was:
  #   handle_closed_issue "$issue_number" "$issue_data"
  #   return 0
  # After the fix, the `return 0` must be replaced by `return $?` to propagate
  # the sentinel.

  # Extract run_workflow function body
  _func_body=$(awk '
    /^run_workflow\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract run_workflow function body" >&2
    return 1
  }

  # handle_closed_issue must be called
  echo "$_func_body" | grep -q "handle_closed_issue" || {
    echo "FAIL: handle_closed_issue not called from run_workflow" >&2
    return 1
  }

  # After the fix, the CLOSED branch must propagate handle_closed_issue's exit code.
  # Accept either form:
  #   Form A: `return $?`       — direct propagation
  #   Form B: `_closed_exit=$?` followed by `return $_closed_exit` — capture form
  #           (preferred under set -e because any intervening command would clobber $?)
  _has_direct=$(echo "$_func_body" | grep -cE 'return \$\?' || true)
  _has_capture=$(echo "$_func_body" | grep -cE '_closed_exit=\$\?' || true)
  if [ "$_has_direct" -eq 0 ] && [ "$_has_capture" -eq 0 ]; then
    echo "FAIL: Neither 'return \$?' nor '_closed_exit=\$?' found in run_workflow body" >&2
    echo "      run_workflow must propagate handle_closed_issue's exit code (12)" >&2
    return 1
  fi

  # The CLOSED branch must NOT have an UNGUARDED `return 0` immediately after
  # handle_closed_issue — that would discard the sentinel in all modes.
  # The implementation legitimately has `return 0` for single-issue mode, but it
  # must be inside a BATCH_MODE guard (i.e. in the `else` branch of an `if BATCH_MODE`
  # block), not as a bare statement that always executes.
  #
  # Strategy: extract the CLOSED block, then remove all lines that are clearly
  # inside an if/else/fi BATCH_MODE guard.  Any `return 0` remaining after that
  # removal is truly unguarded and is a bug.
  _closed_block=$(echo "$_func_body" | awk '
    /issue_state.*CLOSED/ { in_block=1; next }
    in_block && /^[[:space:]]*fi$/ { exit }
    in_block { print $0 }
  ')

  # Strip lines inside any `if ... BATCH_MODE ... fi` block to leave only top-level code.
  _top_level_block=$(echo "$_closed_block" | awk '
    /if \[.*BATCH_MODE/ { in_guard=1; next }
    in_guard && /^[[:space:]]*fi$/ { in_guard=0; next }
    in_guard { next }
    { print $0 }
  ')

  if echo "$_top_level_block" | grep -qE '^\s*return 0$'; then
    echo "FAIL: Unguarded 'return 0' found at top level of CLOSED branch in run_workflow" >&2
    echo "      A bare 'return 0' here discards the exit-12 sentinel from handle_closed_issue" >&2
    echo "      If 'return 0' is intentional for single-issue mode, it must be inside a" >&2
    echo "      BATCH_MODE guard (else branch of 'if [ BATCH_MODE = true ]')" >&2
    return 1
  fi
}

@test "structural: workflow-runner.sh top-level executor has explicit exit 12 case" {
  # The main() / top-level executor must handle exit 12 explicitly (propagate it),
  # otherwise it falls through to the `else` branch and becomes exit 1.

  # The exit-12 handling must exist outside of any function (in the top-level executable body)
  grep -n "exit 12" "$WORKFLOW_RUNNER" | grep -qv "^[0-9]*:#" || {
    # Check that there's at least one non-comment `exit 12` line
    _exit12_lines=$(grep -n "exit 12" "$WORKFLOW_RUNNER" | grep -v "^[0-9]*:.*#" || true)
    [ -n "$_exit12_lines" ] || {
      echo "FAIL: No 'exit 12' found in workflow-runner.sh" >&2
      echo "      The top-level executor must propagate exit 12 so batch sees the sentinel" >&2
      return 1
    }
  }

  # Specifically, there must be an elif/if block checking workflow_exit -eq 12
  grep -qE '\[ \$workflow_exit -eq 12 \]' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'workflow_exit -eq 12' check in workflow-runner.sh top-level executor" >&2
    echo "      Without this, exit 12 from run_workflow falls into the 'else' branch → exit 1" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh captures workflow-runner exit code before if/then" {
  # The fix requires capturing the exit code with:
  #   _WF_EXIT=0
  #   "$RITE_LIB_DIR/core/workflow-runner.sh" ... || _WF_EXIT=$?
  # NOT the old bare:
  #   if "$RITE_LIB_DIR/core/workflow-runner.sh" ...; then
  # The bare form discards exit 12 (only enters the success branch on exit 0).

  # Must have the _WF_EXIT capture pattern
  grep -qE '_WF_EXIT=0' "$BATCH_PROCESSOR" || {
    echo "FAIL: _WF_EXIT=0 initialization not found in batch-process-issues.sh" >&2
    echo "      The exit-code capture pattern requires initializing _WF_EXIT before the cmd" >&2
    return 1
  }

  grep -qE '\|\| _WF_EXIT=\$\?' "$BATCH_PROCESSOR" || {
    echo "FAIL: '|| _WF_EXIT=\$?' pattern not found in batch-process-issues.sh" >&2
    echo "      Exit code must be captured BEFORE any if/then test" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has exit-12 branch (already_closed_at_start)" {
  grep -qE 'elif \[ \$_WF_EXIT -eq 12 \]' "$BATCH_PROCESSOR" || {
    echo "FAIL: No 'elif [ \$_WF_EXIT -eq 12 ]' branch in batch-process-issues.sh" >&2
    echo "      Exit 12 must route to the already_closed_at_start skip path" >&2
    return 1
  }

  grep -q 'already_closed_at_start' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'already_closed_at_start' status not set in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: no gh pr list or gh pr view or gh issue list in exit-12 branch (non-comment)" {
  # Extract the exit-12 branch body — from `elif [ $_WF_EXIT -eq 12 ]`
  # up to the matching `elif [ $_WF_EXIT -eq ...` or `else`.
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 12 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract the exit-12 branch body from batch-process-issues.sh" >&2
    return 1
  }

  # Strip comment lines before checking for gh calls — comments may mention
  # the gh calls as documentation of what is being skipped.
  _noncomment_body=$(echo "$_branch_body" | grep -v '^\s*#')

  # No gh pr list in the branch (non-comment lines only)
  if echo "$_noncomment_body" | grep -qE 'gh.*pr list'; then
    echo "FAIL: 'gh pr list' (non-comment) found in exit-12 branch" >&2
    echo "      This call must be skipped for already-closed issues — no new PR was created" >&2
    return 1
  fi

  # No gh pr view in the branch (non-comment lines only)
  if echo "$_noncomment_body" | grep -qE 'gh.*pr view'; then
    echo "FAIL: 'gh pr view' (non-comment) found in exit-12 branch" >&2
    echo "      PR stat gathering must be skipped for already-closed issues" >&2
    return 1
  fi

  # No gh issue list in the branch (non-comment lines only)
  if echo "$_noncomment_body" | grep -qE 'gh.*issue list'; then
    echo "FAIL: 'gh issue list' (non-comment) found in exit-12 branch" >&2
    echo "      Tech-debt issue search must be skipped for already-closed issues" >&2
    return 1
  fi
}

@test "structural: ALREADY_CLOSED_AT_START_ISSUES array is initialized in batch-process-issues.sh" {
  grep -q 'ALREADY_CLOSED_AT_START_ISSUES=' "$BATCH_PROCESSOR" || {
    echo "FAIL: ALREADY_CLOSED_AT_START_ISSUES array not initialized in batch-process-issues.sh" >&2
    return 1
  }
}

# =============================================================================
# UNIT: batch-reporter.sh handles already_closed_at_start correctly
# =============================================================================

@test "reporter: already_closed_at_start in SKIPPED_ISSUES counts toward Skipped total" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(99 100)
    ALREADY_CLOSED_AT_START_ISSUES=(99 100)
    ISSUE_STATUS[99]='already_closed_at_start'
    ISSUE_STATUS[100]='already_closed_at_start'

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
    _batch_print_stats | grep 'Skipped:'
  "

  [ "$status" -eq 0 ]
  # TOTAL_PROCESSED excludes skipped (2 closed + 1 completed = TOTAL_PROCESSED=1)
  echo "$output" | grep -q "TOTAL_PROCESSED=1"
  # Skipped count includes the 2 already_closed_at_start
  echo "$output" | grep -q "Skipped:.*2"
}

@test "reporter: already_closed_at_start does NOT appear in generic Skipped Issues section" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(99 105)
    ALREADY_CLOSED_AT_START_ISSUES=(99)
    ISSUE_STATUS[99]='already_closed_at_start'
    ISSUE_STATUS[105]='waiting_for_parent'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  # Issue #105 (waiting_for_parent) must appear in the generic Skipped Issues section
  echo "$output" | grep -q "Issue #105"

  # The generic Skipped Issues section must NOT list issue #99 with already_closed_at_start
  # Extract only the lines between "Skipped Issues" header and the next separator/empty
  _skipped_lines=$(echo "$output" | awk '/^Skipped Issues$/{found=1; next} found && /^━/{exit} found{print}')
  # If the skipped section exists, it must not contain already_closed_at_start
  if [ -n "$_skipped_lines" ]; then
    if echo "$_skipped_lines" | grep -q "already_closed_at_start"; then
      echo "FAIL: already_closed_at_start reason appeared in generic Skipped Issues section" >&2
      return 1
    fi
  fi
}

@test "reporter: already_closed_at_start issues appear in 'Already Closed at Start' section" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(99 100)
    ALREADY_CLOSED_AT_START_ISSUES=(99 100)
    ISSUE_STATUS[99]='already_closed_at_start'
    ISSUE_STATUS[100]='already_closed_at_start'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  # Distinct section header must be present
  echo "$output" | grep -q "Already Closed at Start"
  # Both issues must appear in that section
  echo "$output" | grep -q "Issue #99"
  echo "$output" | grep -q "Issue #100"
}

@test "reporter: no 'Already Closed at Start' section when ALREADY_CLOSED_AT_START_ISSUES is empty" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    ALREADY_CLOSED_AT_START_ISSUES=()

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  # Section must NOT appear when array is empty
  ! echo "$output" | grep -q "Already Closed at Start"
}

@test "reporter: TOTAL_PROCESSED excludes already_closed_at_start issues" {
  run bash -c "
    source '${BATCH_REPORTER}'

    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    # 3 already-closed issues in SKIPPED — must NOT inflate TOTAL_PROCESSED
    SKIPPED_ISSUES=(10 11 12)
    ALREADY_CLOSED_AT_START_ISSUES=(10 11 12)

    _batch_compute_totals
    echo \"TOTAL_PROCESSED=\$TOTAL_PROCESSED\"
  "

  [ "$status" -eq 0 ]
  # TOTAL_PROCESSED = completed(2) only — the 3 already-closed are excluded
  echo "$output" | grep -q "TOTAL_PROCESSED=2"
}

@test "reporter: backward compat — works when ALREADY_CLOSED_AT_START_ISSUES is not set" {
  # Old test fixtures that don't declare ALREADY_CLOSED_AT_START_ISSUES must still work.
  # The function defaults to empty array behavior.
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(101)
    ISSUE_STATUS[101]='waiting_for_parent'
    # ALREADY_CLOSED_AT_START_ISSUES intentionally not set

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Total Issues:.*2"
  echo "$output" | grep -q "Skipped:.*1"
  # No Already Closed section (array was not declared)
  ! echo "$output" | grep -q "Already Closed at Start"
}

# =============================================================================
# INTEGRATION: batch summary with mixed issue types
# =============================================================================

@test "integration: batch of 1 active + 2 already-closed — Processed=1, Skipped=2, Completed=1" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    declare -A ISSUE_TIME
    declare -A ISSUE_PR
    ISSUE_LIST=(87 99 100)
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    ALREADY_CLOSED_AT_START_ISSUES=()

    # Issue #87: actively worked on this session — completed
    COMPLETED_ISSUES=\$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS[87]='completed'
    ISSUE_TIME[87]=120
    ISSUE_PR[87]=301

    # Issue #99: already closed when batch started — exit 12 path
    SKIPPED_ISSUES+=(99)
    ALREADY_CLOSED_AT_START_ISSUES+=(99)
    ISSUE_STATUS[99]='already_closed_at_start'
    ISSUE_TIME[99]=1

    # Issue #100: already closed when batch started — exit 12 path
    SKIPPED_ISSUES+=(100)
    ALREADY_CLOSED_AT_START_ISSUES+=(100)
    ISSUE_STATUS[100]='already_closed_at_start'
    ISSUE_TIME[100]=1

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

  # Already-closed section present with both issues
  echo "$output" | grep -q "Already Closed at Start"
  echo "$output" | grep -q "Issue #99"
  echo "$output" | grep -q "Issue #100"

  # Generic Skipped Issues section must NOT appear (no non-already-closed skips)
  ! echo "$output" | grep -q "^Skipped Issues"
}

@test "integration: batch of 1 active + 1 already-closed + 1 dep-deferred — all sections correct" {
  run bash -c "
    source '${BATCH_REPORTER}'

    declare -A ISSUE_STATUS
    declare -A ISSUE_TIME
    declare -A ISSUE_PR
    ISSUE_LIST=(87 99 105)
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    ALREADY_CLOSED_AT_START_ISSUES=()

    # Issue #87: active completion
    COMPLETED_ISSUES=\$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS[87]='completed'
    ISSUE_TIME[87]=90
    ISSUE_PR[87]=302

    # Issue #99: already closed at start
    SKIPPED_ISSUES+=(99)
    ALREADY_CLOSED_AT_START_ISSUES+=(99)
    ISSUE_STATUS[99]='already_closed_at_start'
    ISSUE_TIME[99]=1

    # Issue #105: dep-failed (different skip reason)
    SKIPPED_ISSUES+=(105)
    ISSUE_STATUS[105]='dep_failed'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  echo "$output" | grep -q "Total Issues:.*3"
  echo "$output" | grep -q "Processed:.*1"
  echo "$output" | grep -q "Skipped:.*2"

  # Already Closed section contains #99 only
  echo "$output" | grep -q "Already Closed at Start"
  echo "$output" | grep -q "Issue #99"

  # Generic Skipped Issues section contains #105 only (not #99)
  echo "$output" | grep -q "Skipped Issues"
  echo "$output" | grep -q "Issue #105.*dep_failed"
}
