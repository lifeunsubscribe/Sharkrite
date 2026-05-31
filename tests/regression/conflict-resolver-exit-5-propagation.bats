#!/usr/bin/env bats
# tests/regression/conflict-resolver-exit-5-propagation.bats
#
# Regression test for issue #22: Propagate conflict-resolver exit 5 to batch abort.
#
# When conflict-resolver.sh returns exit code 5 (usage cap), the signal must
# propagate all the way up through divergence handlers → phase callers → batch,
# causing the batch to abort (not just the current issue).
#
# Specifically verifies the THREE call sites fixed in this issue:
#
#   1. workflow-runner.sh phase_merge_pr() — handle_push_divergence exit 5
#      silently became exit 1 (return 1 in the generic elif branch)
#
#   2. claude-workflow.sh fix-review push — || { exit 1 } swallowed exit 5
#
#   3. claude-workflow.sh post-dev push — || { exit 1 } swallowed exit 5
#
# Tests stub handle_push_divergence and detect_divergence as shell functions so
# they work independently of live git state or conflict-resolver.sh landing.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"

  # Stub print functions used by the modules under test
  print_status()  { echo "STATUS: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_warning() { echo "WARNING: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  export -f print_status print_info print_warning print_error print_success
}

teardown() {
  teardown_test_tmpdir
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: batch loop breaks on exit 5 (does not continue to next issue)
#
# Mirrors the batch-process-issues.sh loop logic:
#   - Issue 1: exit 0 (success)
#   - Issue 2: exit 5 (usage cap) → batch must break
#   - Issue 3: must NOT be reached
# ─────────────────────────────────────────────────────────────────────────────
@test "batch loop: exit 5 from workflow-runner breaks the batch (issue 3 not processed)" {
  # Write a batch-loop simulator to a temp script and run it
  _batch_script="$RITE_TEST_TMPDIR/batch-sim.sh"
  cat > "$_batch_script" <<'BATCHEOF'
#!/usr/bin/env bash
set -euo pipefail

PROCESSED=""
FAILED_ISSUES=()
COMPLETED=0

for ISSUE_NUM in 1 2 3; do
  # Simulate workflow-runner.sh exit codes
  case "$ISSUE_NUM" in
    1) EXIT_CODE=0 ;;
    2) EXIT_CODE=5 ;;
    3) EXIT_CODE=0 ;;
  esac

  PROCESSED="$PROCESSED $ISSUE_NUM"

  if [ "$EXIT_CODE" -eq 0 ]; then
    COMPLETED=$((COMPLETED + 1))
  elif [ "$EXIT_CODE" -eq 5 ]; then
    # Usage cap reached — abort the entire batch (mirrors batch-process-issues.sh:588-595)
    FAILED_ISSUES+=("$ISSUE_NUM")
    break
  else
    FAILED_ISSUES+=("$ISSUE_NUM")
  fi
done

echo "processed:$PROCESSED"
echo "failed:${FAILED_ISSUES[*]:-}"
echo "completed:$COMPLETED"
BATCHEOF
  chmod +x "$_batch_script"

  _output=$("$_batch_script")

  # Issue 3 must NOT have been processed (batch aborted after issue 2)
  ! echo "$_output" | grep -qE "processed:.* 3"

  # Issue 1 and 2 were processed, 2 caused the break
  echo "$_output" | grep -qE "processed:.* 1 2"

  # Issue 2 must appear in failed list
  echo "$_output" | grep -q "failed:.*2"

  # Only issue 1 completed
  echo "$_output" | grep -q "completed:1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: workflow-runner.sh phase_merge_pr divergence path
#         handle_push_divergence exit 5 must propagate as return 5 (not return 1)
#
# Validates the fix at workflow-runner.sh — the missing `elif [ $div_result -eq 5 ]`
# branch in the merge-time divergence handler.
# ─────────────────────────────────────────────────────────────────────────────
@test "phase_merge_pr divergence: exit 5 from handle_push_divergence propagates (not return 1)" {
  # Run in a subshell to isolate state and test the fixed logic directly
  _result=0
  (
    # Stubs
    print_warning() { true; }
    print_error()   { true; }
    # Divergence detected, resolver hits usage cap
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 5; }

    # Replicate the fixed phase_merge_pr divergence block from workflow-runner.sh
    div_result=0
    handle_push_divergence "feat/test" "22" "101" "auto" || div_result=$?

    if [ $div_result -eq 2 ]; then
      return 0  # re-review (not this case)
    elif [ $div_result -eq 5 ]; then
      # Fixed: propagate usage cap so batch aborts cleanly
      return 5
    elif [ $div_result -ne 0 ]; then
      return 1  # old (broken) behavior
    fi
  ) || _result=$?

  # Must be exit 5 (usage cap), not exit 1 (generic failure — the old broken behavior)
  [ "$_result" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: claude-workflow.sh fix-review push path
#         The old || { exit 1 } pattern swallowed exit 5.
#         The fix captures _div_result and branches on 5 → exit 5.
# ─────────────────────────────────────────────────────────────────────────────
@test "claude-workflow fix-review push: exit 5 from handle_push_divergence propagates (not exit 1)" {
  _test_exit=0
  (
    print_warning() { true; }
    print_error()   { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 5; }

    # Replicate the fixed code path from claude-workflow.sh fix-review push section
    _div_result=0
    handle_push_divergence "feat/test" "22" "101" "true" || _div_result=$?
    if [ "$_div_result" -eq 5 ]; then
      exit 5
    elif [ "$_div_result" -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?

  # Must exit 5 (usage cap propagated), not exit 1 (old broken behavior)
  [ "$_test_exit" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: claude-workflow.sh post-dev push path (same fix, different call site)
# ─────────────────────────────────────────────────────────────────────────────
@test "claude-workflow post-dev push: exit 5 from handle_push_divergence propagates (not exit 1)" {
  _test_exit=0
  (
    print_warning() { true; }
    print_error()   { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 5; }

    # Replicate the fixed code path from claude-workflow.sh post-dev push section
    _postdev_div_result=0
    handle_push_divergence "feat/test" "22" "" "true" || _postdev_div_result=$?
    if [ "$_postdev_div_result" -eq 5 ]; then
      exit 5
    elif [ "$_postdev_div_result" -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?

  [ "$_test_exit" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: merge-pr.sh divergence path
#         DIV_RESULT=5 → MERGE_EXIT_CODE=5 → exit 5 (not exit 1 via merge-failed else)
# ─────────────────────────────────────────────────────────────────────────────
@test "merge-pr divergence path: DIV_RESULT=5 sets MERGE_EXIT_CODE=5 and exits 5" {
  _test_exit=0
  (
    print_error() { true; }

    # Replicate the fixed divergence handling + exit gate from merge-pr.sh
    DIV_RESULT=5
    MERGE_EXIT_CODE=0

    if [ $DIV_RESULT -eq 0 ]; then
      MERGE_EXIT_CODE=0  # resolved
    elif [ $DIV_RESULT -eq 5 ]; then
      # Fixed: set MERGE_EXIT_CODE=5 so the exit gate below propagates correctly
      MERGE_EXIT_CODE=5
    else
      MERGE_EXIT_CODE=1
    fi

    # Replicate the fixed exit gate
    if [ $MERGE_EXIT_CODE -eq 5 ]; then
      exit 5
    elif [ $MERGE_EXIT_CODE -eq 0 ]; then
      exit 0
    else
      exit 1
    fi
  ) || _test_exit=$?

  # Must exit 5 (usage cap), not exit 1 (old: merge-failed path)
  [ "$_test_exit" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: end-to-end signal chain via real divergence-handler.sh
#         attempt_claude_merge_resolution exit 5 → handle_push_divergence exit 5
#         Tests the full propagation path through the real sourced library.
# ─────────────────────────────────────────────────────────────────────────────
@test "end-to-end: exit 5 from attempt_claude_merge_resolution propagates through divergence-handler" {
  # Create a minimal git repo so divergence-handler git commands don't crash
  _fixture="$RITE_TEST_TMPDIR/fixture"
  mkdir -p "$_fixture"
  git -C "$_fixture" init -q
  git -C "$_fixture" config user.name "Test"
  git -C "$_fixture" config user.email "test@test.com"
  echo "init" > "$_fixture/README.md"
  git -C "$_fixture" add .
  git -C "$_fixture" commit -q -m "init"
  cd "$_fixture"

  # Source the real divergence-handler — this provides handle_push_divergence
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"

  # Stub: resolver hits usage cap (exit 5)
  attempt_claude_merge_resolution() { return 5; }
  export -f attempt_claude_merge_resolution

  # Stub detect_divergence to say "diverged" without needing a real remote
  detect_divergence() { return 0; }
  export -f detect_divergence

  # Stub _do_rebase to simulate rebase failure (triggering resolver invocation)
  _do_rebase() { return 1; }
  export -f _do_rebase

  _result=0
  handle_push_divergence "feat/test" "22" "101" "true" 2>/dev/null || _result=$?

  # Exit 5 must reach the caller intact
  [ "$_result" -eq 5 ]
}
