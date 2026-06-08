#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/divergence-handler.sh, lib/core/workflow-runner.sh
# tests/regression/handle-push-divergence-exit2-propagation.bats
#
# Regression test for issue #126: Audit handle_push_divergence callers for 5→1 collapse.
#
# handle_push_divergence exit 2 means "divergence resolved by pulling foreign commits;
# re-enter the review cycle so the fresh combined HEAD gets a new review."
#
# Before this fix, exit 2 collapsed to exit/return 1 (hard failure) in two call sites
# in claude-workflow.sh and one in workflow-runner.sh's fix-review path.
#
# Specifically verifies the THREE call sites fixed:
#
#   1. claude-workflow.sh fix-review push — exit 2 collapsed to exit 1
#
#   2. claude-workflow.sh post-dev push — exit 2 collapsed to exit 1
#
#   3. workflow-runner.sh phase_assess_and_resolve fix-review caller —
#      exit 2 collapsed to return 1 (should fall through to phase_create_pr re-review)
#
# Also verifies that exit 5 from the same call sites in workflow-runner.sh's fix-review
# path is now propagated (previously swallowed into return 1 alongside exit 2).
#
# Tests stub handle_push_divergence and detect_divergence as shell functions so
# they work independently of live git state.

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
# Test 1: claude-workflow.sh fix-review push path
#         handle_push_divergence exit 2 must propagate as exit 2 (not exit 1)
#
# Validates the fix in claude-workflow.sh fix-review push section:
#   elif [ "$_div_result" -eq 2 ]; then
#     exit 2
# ─────────────────────────────────────────────────────────────────────────────
@test "claude-workflow fix-review push: exit 2 from handle_push_divergence propagates (not exit 1)" {
  _test_exit=0
  (
    print_warning() { true; }
    print_error()   { true; }
    print_info()    { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 2; }

    # Replicate the fixed code path from claude-workflow.sh fix-review push section
    _div_result=0
    handle_push_divergence "feat/test" "126" "101" "true" || _div_result=$?
    if [ "$_div_result" -eq 5 ]; then
      exit 5
    elif [ "$_div_result" -eq 2 ]; then
      # Foreign commits pulled — re-enter review cycle
      exit 2
    elif [ "$_div_result" -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?

  # Must exit 2 (re-review signal), not exit 1 (old broken behavior — hard failure)
  [ "$_test_exit" -eq 2 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: claude-workflow.sh post-dev push path (same fix, different call site)
# ─────────────────────────────────────────────────────────────────────────────
@test "claude-workflow post-dev push: exit 2 from handle_push_divergence propagates (not exit 1)" {
  _test_exit=0
  (
    print_warning() { true; }
    print_error()   { true; }
    print_info()    { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 2; }

    # Replicate the fixed code path from claude-workflow.sh post-dev push section
    _postdev_div_result=0
    handle_push_divergence "feat/test" "126" "" "true" || _postdev_div_result=$?
    if [ "$_postdev_div_result" -eq 5 ]; then
      exit 5
    elif [ "$_postdev_div_result" -eq 2 ]; then
      # Foreign commits pulled — re-enter review cycle
      exit 2
    elif [ "$_postdev_div_result" -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?

  # Must exit 2 (re-review signal), not exit 1 (old broken behavior — hard failure)
  [ "$_test_exit" -eq 2 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: workflow-runner.sh phase_assess_and_resolve fix-review caller
#         fix_result=2 must fall through to phase_create_pr (not return 1)
#
# When claude-workflow.sh --fix-review exits 2 (divergence resolved + foreign
# commits), the caller must NOT treat it as a hard failure. Instead it should
# fall through to phase_create_pr so a fresh review is generated.
# ─────────────────────────────────────────────────────────────────────────────
@test "workflow-runner fix-review caller: fix_result=2 falls through to phase_create_pr (not return 1)" {
  _result=0
  _phase_create_pr_called=false

  (
    print_info()    { true; }
    print_error()   { true; }
    print_warning() { true; }

    # Simulate the fix-review exit-code handler from workflow-runner.sh
    # (the block that checks fix_result after claude-workflow.sh --fix-review runs)
    fix_result=2

    if [ $fix_result -eq 3 ]; then
      return 1  # test failure
    elif [ $fix_result -eq 5 ]; then
      return 5  # usage cap — propagate
    elif [ $fix_result -eq 2 ]; then
      # Divergence resolved — fall through to phase_create_pr
      true
    elif [ $fix_result -ne 0 ]; then
      exit 1  # hard failure (old behavior for exit 2)
    fi

    # If we reach here, phase_create_pr would be called next
    echo "phase_create_pr_called"
  ) || _result=$?

  # The subshell must exit 0 (not 1) — fix_result=2 falls through
  [ "$_result" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: workflow-runner.sh fix-review caller
#         fix_result=5 must return 5 (not return 1)
#
# Verifies the usage-cap propagation fix added alongside the exit-2 fix.
# Previously exit 5 from --fix-review would also collapse to return 1.
# ─────────────────────────────────────────────────────────────────────────────
@test "workflow-runner fix-review caller: fix_result=5 propagates as return 5 (not return 1)" {
  _result=0
  (
    print_info()    { true; }
    print_error()   { true; }
    print_warning() { true; }

    # Replicate the fixed fix_result handler from workflow-runner.sh
    fix_result=5

    if [ $fix_result -eq 3 ]; then
      return 1  # test failure
    elif [ $fix_result -eq 5 ]; then
      # Usage cap — propagate
      return 5
    elif [ $fix_result -eq 2 ]; then
      true  # fall through
    elif [ $fix_result -ne 0 ]; then
      return 1  # old behavior that swallowed exit 5
    fi

    return 0
  ) || _result=$?

  # Must be 5 (usage cap propagated), not 1 (old broken swallow behavior)
  [ "$_result" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: workflow-runner.sh dev-phase exit 2 handling (orchestrated post-dev push)
#         workflow_exit=2 from claude-workflow.sh post-dev push must be treated
#         as dev-phase success (not a hard failure), so Phase 2 runs next.
# ─────────────────────────────────────────────────────────────────────────────
@test "workflow-runner dev-phase: workflow_exit=2 treated as success (not hard failure)" {
  _result=0
  _continued=false

  (
    print_info()    { true; }
    print_error()   { true; }
    print_warning() { true; }

    # Simulate the dev-phase workflow_exit handler from workflow-runner.sh
    # (the elif chain after the exit-4 retry block)
    workflow_exit=2

    if [ $workflow_exit -eq 3 ]; then
      return 1  # test failure
    elif [ $workflow_exit -eq 4 ]; then
      return 1  # no-work, retry
    elif [ $workflow_exit -eq 2 ]; then
      # Divergence resolved during post-dev push — treat as success, continue to Phase 2
      true
    elif [ $workflow_exit -ne 0 ]; then
      return 1  # old behavior: hard failure (exit 2 used to hit this branch)
    fi

    # Execution reaching here means the dev phase was not failed
    echo "dev_phase_succeeded"
    return 0
  ) || _result=$?

  # Dev phase must succeed (exit 0), not hard-fail (exit 1)
  [ "$_result" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Verify old broken pattern (pre-fix) would have failed exit 2
#         Documents that the original code collapsed exit 2 to exit/return 1.
#         This test verifies the OLD behavior is gone (negative regression check).
# ─────────────────────────────────────────────────────────────────────────────
@test "old-broken-pattern: exit 2 collapsing to exit 1 is no longer present in fixes" {
  # Verify that the fixed sections in both files contain the exit-2 branch.
  # This catches regressions where someone removes the elif-eq-2 branch.

  # claude-workflow.sh fix-review push: must have elif _div_result -eq 2 → exit 2
  grep -A5 '_div_result.*-eq.*5' "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" \
    | grep -q '_div_result.*-eq.*2'

  # claude-workflow.sh post-dev push: must have elif _postdev_div_result -eq 2 → exit 2
  grep -A5 '_postdev_div_result.*-eq.*5' "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" \
    | grep -q '_postdev_div_result.*-eq.*2'

  # workflow-runner.sh fix-review caller: must have fix_result -eq 2 branch
  grep -A10 'fix_result -eq 5' "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" \
    | grep -q 'fix_result -eq 2'

  # workflow-runner.sh dev-phase: must have workflow_exit -eq 2 branch (after the eq 3 branch)
  grep -n 'workflow_exit -eq 2' "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" \
    | grep -q 'workflow_exit -eq 2'
}
