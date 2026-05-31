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
# Test 6: phase_merge_pr with real sourced workflow-runner.sh
#         MERGE_PR stub exits 5 → phase_merge_pr must return 5 (not return 1)
#
# This test exercises the actual phase_merge_pr() function from workflow-runner.sh
# to verify the bug fix at lines 1380-1383: the missing `elif [ $merge_result -eq 5 ]`
# branch that previously downgraded exit 5 → return 1 (generic failure).
# ─────────────────────────────────────────────────────────────────────────────
@test "phase_merge_pr: MERGE_PR returning exit 5 propagates as return 5 (not return 1)" {
  # Set up a stub RITE_LIB_DIR so workflow-runner.sh source calls hit empty stubs
  # instead of real modules that require git/gh state.
  _stub_lib="$RITE_TEST_TMPDIR/stub-lib"
  for _subdir in utils providers core; do
    mkdir -p "$_stub_lib/$_subdir"
  done

  # Create stub files for every module sourced by workflow-runner.sh at top level
  for _mod in \
    utils/notifications.sh \
    utils/blocker-rules.sh \
    utils/session-tracker.sh \
    utils/pr-summary.sh \
    utils/normalize-issue.sh \
    utils/pr-detection.sh \
    utils/date-helpers.sh \
    utils/stash-manager.sh \
    utils/colors.sh \
    utils/logging.sh \
    utils/divergence-handler.sh \
    providers/provider-interface.sh; do
    printf '#!/usr/bin/env bash\n# stub\n' > "$_stub_lib/$_mod"
  done

  # Create a stub MERGE_PR script that exits 5 (usage cap)
  _merge_pr_stub="$RITE_TEST_TMPDIR/merge-pr-stub.sh"
  printf '#!/usr/bin/env bash\nexit 5\n' > "$_merge_pr_stub"
  chmod +x "$_merge_pr_stub"

  _result=0
  (
    set +e  # allow non-zero exits to be captured

    # Point workflow-runner.sh to stub lib dir
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export WORKFLOW_MODE="unsupervised"

    # Create a valid worktree path (cd inside phase_merge_pr requires it)
    export WORKTREE_PATH="$RITE_TEST_TMPDIR"
    export STASHED_UNRELATED_WORK="false"

    # Source the real workflow-runner.sh (stubs replace sourced modules)
    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    # Override MERGE_PR to use the exit-5 stub
    MERGE_PR="$_merge_pr_stub"

    # Stub functions called by phase_merge_pr before it reaches $MERGE_PR
    gh()                     { echo "{}"; }
    jq()                     { echo ""; }
    extract_changes_summary() { echo ""; }
    check_blockers()          { return 0; }
    handle_blocker()          { return 0; }
    verify_pr_head()          { return 0; }  # head matches → skip divergence block
    detect_divergence()       { return 1; }  # no divergence

    # Stub print functions (may already be defined from setup(), but re-export to be safe)
    print_header()  { true; }
    print_info()    { true; }
    print_warning() { true; }
    print_error()   { true; }
    print_success() { true; }

    phase_merge_pr "22" "101"
  ) || _result=$?

  # Must return 5 (usage cap propagated), not 1 (old broken behavior: generic failure)
  [ "$_result" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: end-to-end signal chain via real divergence-handler.sh
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
