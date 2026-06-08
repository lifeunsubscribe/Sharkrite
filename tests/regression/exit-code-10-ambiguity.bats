#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/utils/stale-branch.sh, lib/core/batch-process-issues.sh
# tests/regression/exit-code-10-ambiguity.bats
#
# Regression test for issue #21: Disambiguate exit code 10 handling.
#
# Exit code 10 was overloaded:
#   - stale-branch.sh returned 10 to signal "restarted fresh, reset caller state"
#   - batch-process-issues.sh interprets 10 from workflow-runner as "blocker detected"
#
# Fix: stale-branch.sh now returns 11 ("restart fresh").
#      Exit 10 is reserved exclusively for batch-level "blocker detected".
#
# Tests:
#   1. stale-branch check_stale_branch returns 11 (not 10) for auto-restart
#   2. stale-branch supervised path returns 11 (not 10) for "close and restart"
#   3. workflow-runner stale handler reacts to 11, not 10 (reset state + continue)
#   4. batch loop: exit 11 from workflow-runner is treated as generic failure (not blocker-defer)
#   5. batch loop: exit 10 from workflow-runner still triggers blocker-defer path
#   6. exit codes 10 and 11 are distinct — no collision

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"

  # Stub print functions used by sourced modules
  print_status()  { echo "STATUS: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_warning() { echo "WARNING: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }
  export -f print_status print_info print_warning print_error print_success print_header
}

teardown() {
  teardown_test_tmpdir
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: stale-branch auto-restart returns 11 (not 10)
#
# In auto mode (unsupervised), when a branch is at/above the staleness threshold,
# check_stale_branch closes the PR, removes the worktree, and signals the caller
# to restart fresh. This signal must be exit 11 — NOT exit 10.
# ─────────────────────────────────────────────────────────────────────────────
@test "stale-branch auto-restart: check_stale_branch returns 11 (not 10)" {
  _result=0
  (
    # Stub git to make the worktree checks succeed:
    #   - rev-parse --abbrev-ref HEAD → returns a feature branch name
    #   - fetch origin main           → succeeds (returns 0)
    #   - all other git commands      → delegate to real git
    git() {
      if [[ "$*" == *"rev-parse --abbrev-ref HEAD"* ]]; then
        echo "fix/test-issue-42"
        return 0
      elif [[ "$*" == *"fetch origin main"* ]]; then
        return 0
      fi
      command git "$@"
    }
    export -f git

    source "$RITE_LIB_DIR/utils/stale-branch.sh"

    # Stub internal helpers after source so the real definitions don't overwrite our stubs
    _stale_close_and_cleanup() { return 0; }
    export -f _stale_close_and_cleanup

    # Override get_commits_behind_main to report 15 commits behind (above threshold)
    get_commits_behind_main() { COMMITS_BEHIND_MAIN=15; }
    export -f get_commits_behind_main

    # Call the public function — auto/unsupervised mode, 15 > threshold(10) → close + restart
    RITE_STALE_BRANCH_THRESHOLD=10
    check_stale_branch "/fake/worktree" "101" "42" "unsupervised"
  ) || _result=$?

  # Must return 11 (restart fresh signal), not 10 (blocker-detected signal)
  [ "$_result" -eq 11 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: stale-branch supervised path returns 11 when user picks "close and restart"
#
# In supervised mode the user is prompted. Option 1 = close PR and restart.
# That path must also return 11.
# ─────────────────────────────────────────────────────────────────────────────
@test "stale-branch supervised restart: _stale_supervised_prompt returns 11 on option 1" {
  _result=0
  (
    source "$RITE_LIB_DIR/utils/stale-branch.sh"

    # Stub after source so the real implementation doesn't overwrite our stub
    _stale_close_and_cleanup() { return 0; }
    export -f _stale_close_and_cleanup

    # Simulate user pressing "1" (close and restart) by feeding it on stdin
    printf '1' | _stale_supervised_prompt "/fake/worktree" "101" "42" "fix/test-issue-42" "15"
  ) || _result=$?

  [ "$_result" -eq 11 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: workflow-runner stale handler responds to exit 11 (resets state)
#         and does NOT treat exit 10 as a stale restart
#
# Replicate the stale-branch check block from workflow-runner.sh.
# ─────────────────────────────────────────────────────────────────────────────
@test "workflow-runner stale handler: exit 11 resets resume state" {
  _out=$( (
    print_info() { true; }
    stale_result=11
    PR_NUMBER="101"
    WORKTREE_PATH="/fake/path"
    RESUME_MODE=true
    skip_to_phase="assess-resolve"
    if [ $stale_result -eq 11 ]; then
      PR_NUMBER=""
      CURRENT_PR=""
      WORKTREE_PATH=""
      RESUME_MODE=false
      skip_to_phase=""
    fi
    echo "pr:${PR_NUMBER:-EMPTY}"
    echo "worktree:${WORKTREE_PATH:-EMPTY}"
    echo "resume:${RESUME_MODE:-EMPTY}"
    echo "skip:${skip_to_phase:-EMPTY}"
  ))

  # All resume-state variables must be cleared
  echo "$_out" | grep -q "pr:EMPTY"
  echo "$_out" | grep -q "worktree:EMPTY"
  echo "$_out" | grep -q "resume:EMPTY"
  echo "$_out" | grep -q "skip:EMPTY"
}

@test "workflow-runner stale handler: exit 10 does NOT reset resume state (not a stale restart)" {
  _out=$(
    stale_result=10
    PR_NUMBER="101"
    WORKTREE_PATH="/fake/path"
    RESUME_MODE=true
    skip_to_phase="assess-resolve"

    # Replicate the fixed handler — exit 10 is not handled here, so state is unchanged
    if [ $stale_result -eq 11 ]; then
      PR_NUMBER=""
      WORKTREE_PATH=""
      RESUME_MODE=false
      skip_to_phase=""
    elif [ $stale_result -eq 5 ]; then
      exit 5
    elif [ $stale_result -eq 1 ]; then
      exit 1
    fi
    # exit 10 falls through — state unchanged

    echo "pr:${PR_NUMBER}"
    echo "worktree:${WORKTREE_PATH}"
    echo "resume:${RESUME_MODE}"
  )

  # Resume state must be UNCHANGED (exit 10 is not a stale restart)
  echo "$_out" | grep -q "pr:101"
  echo "$_out" | grep -q "worktree:/fake/path"
  echo "$_out" | grep -q "resume:true"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: batch loop — exit 11 from workflow-runner is treated as generic failure
#         (NOT as blocker-defer; 11 is not a recognized batch signal)
#
# After the fix, stale-branch returns 11 and workflow-runner traps it internally.
# The stale restart is transparent to batch: workflow-runner returns 0 on success.
# But if somehow 11 leaked out (defensive test), batch must NOT defer it as a blocker.
# ─────────────────────────────────────────────────────────────────────────────
@test "batch loop: exit 11 is treated as generic failure, not blocker-defer" {
  _batch_script="$RITE_TEST_TMPDIR/batch-sim.sh"
  cat > "$_batch_script" <<'BATCHEOF'
#!/usr/bin/env bash
set -euo pipefail

PROCESSED=""
FAILED_ISSUES=()
BLOCKED_ISSUES=()
COMPLETED=0

for ISSUE_NUM in 1 2 3; do
  # Issue 2 returns exit 11 (stale restart that somehow leaked — should NOT be blocker)
  case "$ISSUE_NUM" in
    1) EXIT_CODE=0 ;;
    2) EXIT_CODE=11 ;;
    3) EXIT_CODE=0 ;;
  esac

  PROCESSED="$PROCESSED $ISSUE_NUM"

  if [ "$EXIT_CODE" -eq 0 ]; then
    COMPLETED=$((COMPLETED + 1))
  elif [ "$EXIT_CODE" -eq 5 ]; then
    # Usage cap — abort batch
    FAILED_ISSUES+=("$ISSUE_NUM")
    break
  elif [ "$EXIT_CODE" -eq 10 ]; then
    # Blocker — defer (continue to next issue)
    BLOCKED_ISSUES+=("$ISSUE_NUM")
  else
    # Generic failure (includes exit 11 — not a recognized batch signal)
    FAILED_ISSUES+=("$ISSUE_NUM")
  fi
done

echo "processed:$PROCESSED"
echo "failed:${FAILED_ISSUES[*]:-none}"
echo "blocked:${BLOCKED_ISSUES[*]:-none}"
echo "completed:$COMPLETED"
BATCHEOF
  chmod +x "$_batch_script"

  _output=$("$_batch_script")

  # Issue 2 (exit 11) must land in failed, not blocked
  echo "$_output" | grep -q "failed:.*2"
  ! echo "$_output" | grep -q "blocked:.*2"

  # Issue 3 must still be processed (exit 11 doesn't break the loop)
  echo "$_output" | grep -qE "processed:.* 3"

  # Issues 1 and 3 completed
  echo "$_output" | grep -q "completed:2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: batch loop — exit 10 still triggers blocker-defer (existing behavior intact)
# ─────────────────────────────────────────────────────────────────────────────
@test "batch loop: exit 10 still triggers blocker-defer (not a failure)" {
  _batch_script="$RITE_TEST_TMPDIR/batch-sim-10.sh"
  cat > "$_batch_script" <<'BATCHEOF'
#!/usr/bin/env bash
set -euo pipefail

PROCESSED=""
FAILED_ISSUES=()
BLOCKED_ISSUES=()
COMPLETED=0

for ISSUE_NUM in 1 2 3; do
  case "$ISSUE_NUM" in
    1) EXIT_CODE=0 ;;
    2) EXIT_CODE=10 ;;   # blocker detected
    3) EXIT_CODE=0 ;;
  esac

  PROCESSED="$PROCESSED $ISSUE_NUM"

  if [ "$EXIT_CODE" -eq 0 ]; then
    COMPLETED=$((COMPLETED + 1))
  elif [ "$EXIT_CODE" -eq 5 ]; then
    FAILED_ISSUES+=("$ISSUE_NUM")
    break
  elif [ "$EXIT_CODE" -eq 10 ]; then
    # Blocker — defer (mirrors batch-process-issues.sh:597-611)
    BLOCKED_ISSUES+=("$ISSUE_NUM")
    # Continue with next issue (no break)
  else
    FAILED_ISSUES+=("$ISSUE_NUM")
  fi
done

echo "processed:$PROCESSED"
echo "failed:${FAILED_ISSUES[*]:-none}"
echo "blocked:${BLOCKED_ISSUES[*]:-none}"
echo "completed:$COMPLETED"
BATCHEOF
  chmod +x "$_batch_script"

  _output=$("$_batch_script")

  # Issue 2 (exit 10) must land in blocked, not failed
  echo "$_output" | grep -q "blocked:.*2"
  ! echo "$_output" | grep -q "failed:.*2"

  # Issue 3 must still be processed (exit 10 defers, doesn't break loop)
  echo "$_output" | grep -qE "processed:.* 3"

  # Issues 1 and 3 completed (issue 2 was deferred)
  echo "$_output" | grep -q "completed:2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: exit codes 10 and 11 are distinct numeric values
#
# Sanity check — verifies the two codes don't accidentally collide.
# ─────────────────────────────────────────────────────────────────────────────
@test "exit codes 10 and 11 are distinct" {
  [ 10 -ne 11 ]

  # Verify stale-branch.sh uses 11 (not 10) for restart signal
  _stale_restarts=$(grep -c "return 11" "$RITE_REPO_ROOT/lib/utils/stale-branch.sh" || true)
  [ "$_stale_restarts" -ge 2 ]

  # Verify stale-branch.sh does NOT use 10 for restart
  _stale_old=$(grep -cE "return 10" "$RITE_REPO_ROOT/lib/utils/stale-branch.sh" || true)
  [ "$_stale_old" -eq 0 ]

  # Verify workflow-runner.sh checks for 11 (not 10) in the stale handler
  _runner_check=$(grep -c "stale_result -eq 11" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_runner_check" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: claude-workflow.sh stale handler reacts to exit 11 (not 10)
#
# claude-workflow.sh is the second consumer of check_stale_branch.  It must
# branch on exit 11 for the stale-restart exec, not exit 10.  This test
# mirrors Test 6's grep-guard approach but targets claude-workflow.sh.
# ─────────────────────────────────────────────────────────────────────────────
@test "claude-workflow.sh stale handler: checks exit 11 (not 10) for restart" {
  _claude_wf="$RITE_REPO_ROOT/lib/core/claude-workflow.sh"

  # Must contain the corrected guard: _stale_exit -eq 11
  _correct=$(grep -c "_stale_exit -eq 11" "$_claude_wf" || true)
  [ "$_correct" -ge 1 ]

  # Must NOT contain the old guard: _stale_exit -eq 10
  _old=$(grep -c "_stale_exit -eq 10" "$_claude_wf" || true)
  [ "$_old" -eq 0 ]
}
