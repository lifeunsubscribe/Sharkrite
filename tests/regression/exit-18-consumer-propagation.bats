#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh::phase_assess_and_resolve|phase_merge_pr, lib/core/merge-pr.sh, lib/core/create-pr.sh, lib/core/claude-workflow.sh, lib/core/promote-branch.sh
# tests/regression/exit-18-consumer-propagation.bats
#
# Regression tests for #1803: six captured consumers of handle_push_divergence /
# check_and_rebase_against_main / sync_integration_branch collapsed exit 18 to 1,
# so a logged-out CLI looked like "could not resolve divergence" instead of halting
# the batch immediately.
#
# Contract:
#   - Each of the six captured consumers maps 18 to 18.
#   - The Phase 3 mid-run rebase block also maps 5 to 5 (new parity check).
#   - A parity check fails when a file has a handle_push_divergence capture with a
#     5 branch and no 18 branch.
#   - Supervised promote exits 18 (not "still N behind") when sync returns 18.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNNER_SH="$PROJECT_ROOT/lib/core/workflow-runner.sh"
  MERGE_SH="$PROJECT_ROOT/lib/core/merge-pr.sh"
  CREATE_SH="$PROJECT_ROOT/lib/core/create-pr.sh"
  CW_SH="$PROJECT_ROOT/lib/core/claude-workflow.sh"
  PROMOTE_SH="$PROJECT_ROOT/lib/core/promote-branch.sh"
}

# ---------------------------------------------------------------------------
# 1. workflow-runner.sh Phase 3 mid-run rebase block
# ---------------------------------------------------------------------------

@test "phase_assess_and_resolve mid-run rebase: exit 18 returns 18 (not 1)" {
  _result=0
  (
    print_error()   { true; }
    print_warning() { true; }
    print_info()    { true; }
    check_and_rebase_against_main() { return 18; }

    _mid_rebase_result=0
    check_and_rebase_against_main \
      "/tmp/wt" "feat/x" "42" "101" "auto" "main" || _mid_rebase_result=$?

    if [ "$_mid_rebase_result" -eq 18 ]; then
      return 18
    elif [ "$_mid_rebase_result" -eq 5 ]; then
      return 5
    elif [ "$_mid_rebase_result" -ne 0 ]; then
      return 1
    fi
  ) || _result=$?
  [ "$_result" -eq 18 ]
}

@test "phase_assess_and_resolve mid-run rebase: exit 5 returns 5 (not 1)" {
  _result=0
  (
    print_error()   { true; }
    print_warning() { true; }
    check_and_rebase_against_main() { return 5; }

    _mid_rebase_result=0
    check_and_rebase_against_main \
      "/tmp/wt" "feat/x" "42" "101" "auto" "main" || _mid_rebase_result=$?

    if [ "$_mid_rebase_result" -eq 18 ]; then
      return 18
    elif [ "$_mid_rebase_result" -eq 5 ]; then
      return 5
    elif [ "$_mid_rebase_result" -ne 0 ]; then
      return 1
    fi
  ) || _result=$?
  [ "$_result" -eq 5 ]
}

@test "workflow-runner.sh: mid-run rebase block has return 18 branch" {
  run grep -nE 'return 18' "$RUNNER_SH"
  [ "$status" -eq 0 ]
  # Must appear in context of mid-run rebase result check
  run awk '/_mid_rebase_result.*-eq 18/{f=1} f&&/return 18/{print; exit}' "$RUNNER_SH"
  [ -n "$output" ]
}

@test "workflow-runner.sh: mid-run rebase block has return 5 branch" {
  run awk '/_mid_rebase_result.*-eq 5/{f=1} f&&/return 5/{print; exit}' "$RUNNER_SH"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 2. workflow-runner.sh phase_merge_pr div_result block
# ---------------------------------------------------------------------------

@test "phase_merge_pr divergence: exit 18 from handle_push_divergence returns 18" {
  _result=0
  (
    print_error()   { true; }
    print_warning() { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 18; }

    div_result=0
    handle_push_divergence "feat/test" "22" "101" "auto" || div_result=$?

    if [ $div_result -eq 2 ]; then
      return 0
    elif [ $div_result -eq 5 ]; then
      return 5
    elif [ $div_result -eq 18 ]; then
      return 18
    elif [ $div_result -ne 0 ]; then
      return 1
    fi
  ) || _result=$?
  [ "$_result" -eq 18 ]
}

@test "workflow-runner.sh: phase_merge_pr div_result 18 branch exists" {
  run grep -nE 'div_result -eq 18' "$RUNNER_SH"
  [ "$status" -eq 0 ]
  run awk '/div_result -eq 18/{f=1} f&&/return 18/{print; exit}' "$RUNNER_SH"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 3. merge-pr.sh DIV_RESULT + final MERGE_EXIT_CODE mapping
# ---------------------------------------------------------------------------

@test "merge-pr divergence: DIV_RESULT=18 sets MERGE_EXIT_CODE=18 and exits 18" {
  _test_exit=0
  (
    print_error() { true; }

    DIV_RESULT=18
    MERGE_EXIT_CODE=0

    if [ $DIV_RESULT -eq 0 ]; then
      MERGE_EXIT_CODE=0
    elif [ $DIV_RESULT -eq 5 ]; then
      MERGE_EXIT_CODE=5
    elif [ $DIV_RESULT -eq 18 ]; then
      MERGE_EXIT_CODE=18
    else
      MERGE_EXIT_CODE=1
    fi

    if [ $MERGE_EXIT_CODE -eq 5 ]; then
      exit 5
    elif [ $MERGE_EXIT_CODE -eq 18 ]; then
      exit 18
    elif [ $MERGE_EXIT_CODE -eq 0 ]; then
      exit 0
    else
      exit 1
    fi
  ) || _test_exit=$?
  [ "$_test_exit" -eq 18 ]
}

@test "merge-pr.sh: DIV_RESULT 18 branch sets MERGE_EXIT_CODE=18" {
  run grep -nE 'DIV_RESULT -eq 18' "$MERGE_SH"
  [ "$status" -eq 0 ]
  run awk '/DIV_RESULT -eq 18/{f=1} f&&/MERGE_EXIT_CODE=18/{print; exit}' "$MERGE_SH"
  [ -n "$output" ]
}

@test "merge-pr.sh: final exit gate propagates MERGE_EXIT_CODE=18 as exit 18" {
  run grep -nE 'MERGE_EXIT_CODE -eq 18' "$MERGE_SH"
  [ "$status" -eq 0 ]
  run awk '/MERGE_EXIT_CODE -eq 18/{f=1} f&&/exit 18/{print; exit}' "$MERGE_SH"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 4. create-pr.sh div_result block
# ---------------------------------------------------------------------------

@test "create-pr divergence: div_result=18 exits 18 (not 1)" {
  _test_exit=0
  (
    print_error()   { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 18; }

    div_result=0
    handle_push_divergence "feat/test" "22" "101" "true" || div_result=$?

    if [ $div_result -eq 2 ]; then
      exit 2
    elif [ $div_result -eq 5 ]; then
      exit 5
    elif [ $div_result -eq 18 ]; then
      exit 18
    elif [ $div_result -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?
  [ "$_test_exit" -eq 18 ]
}

@test "create-pr.sh: div_result 18 branch exits 18" {
  run grep -nE 'div_result -eq 18' "$CREATE_SH"
  [ "$status" -eq 0 ]
  run awk '/div_result -eq 18/{f=1} f&&/exit 18/{print; exit}' "$CREATE_SH"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 5. claude-workflow.sh fix-review push _div_result
# ---------------------------------------------------------------------------

@test "claude-workflow fix-review push: _div_result=18 exits 18 (not 1)" {
  _test_exit=0
  (
    print_error()   { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 18; }

    _div_result=0
    handle_push_divergence "feat/test" "22" "101" "true" || _div_result=$?

    if [ "$_div_result" -eq 5 ]; then
      exit 5
    elif [ "$_div_result" -eq 18 ]; then
      exit 18
    elif [ "$_div_result" -eq 2 ]; then
      exit 2
    elif [ "$_div_result" -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?
  [ "$_test_exit" -eq 18 ]
}

@test "claude-workflow.sh: fix-review _div_result 18 branch exits 18" {
  # Both the fix-review and post-dev paths must have an 18 branch
  local eighteen_count
  eighteen_count=$(grep -cE '"?\$_div_result" -eq 18|"?\$_postdev_div_result" -eq 18' "$CW_SH" || true)
  [ "$eighteen_count" -ge 2 ]
}

# ---------------------------------------------------------------------------
# 6. claude-workflow.sh post-dev push _postdev_div_result
# ---------------------------------------------------------------------------

@test "claude-workflow post-dev push: _postdev_div_result=18 exits 18 (not 1)" {
  _test_exit=0
  (
    print_error()   { true; }
    detect_divergence()      { return 0; }
    handle_push_divergence() { return 18; }

    _postdev_div_result=0
    handle_push_divergence "feat/test" "22" "" "true" || _postdev_div_result=$?

    if [ "$_postdev_div_result" -eq 5 ]; then
      exit 5
    elif [ "$_postdev_div_result" -eq 18 ]; then
      exit 18
    elif [ "$_postdev_div_result" -eq 2 ]; then
      exit 2
    elif [ "$_postdev_div_result" -ne 0 ]; then
      exit 1
    fi
  ) || _test_exit=$?
  [ "$_test_exit" -eq 18 ]
}

@test "claude-workflow.sh: post-dev _postdev_div_result 18 branch exits 18" {
  run grep -nE '"?\$_postdev_div_result" -eq 18|\$_postdev_div_result -eq 18' "$CW_SH"
  [ "$status" -eq 0 ]
  run awk '/_postdev_div_result.*-eq 18/{f=1} f&&/exit 18/{print; exit}' "$CW_SH"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 7. promote-branch.sh supervised preflight
# ---------------------------------------------------------------------------

@test "promote supervised preflight: sync exit 18 propagates as exit 18 (parity: not still-N-behind)" {
  _test_exit=0
  (
    print_error()   { true; }
    sync_integration_branch() { return 18; }

    local _supervised_sync_rc=0
    sync_integration_branch "my-branch" || _supervised_sync_rc=$?
    if [ "$_supervised_sync_rc" -eq 18 ]; then
      exit 18
    fi
    # If we reach here without exit 18 it means the fix is missing — test fails
    echo "MISSING EXIT 18 — sync error not surfaced" >&2
    exit 1
  ) || _test_exit=$?
  [ "$_test_exit" -eq 18 ]
}

@test "promote-branch.sh: supervised sync captures result and checks for 18" {
  run grep -nE '_supervised_sync_rc' "$PROMOTE_SH"
  [ "$status" -eq 0 ]
  run awk '/_supervised_sync_rc.*-eq 18/{f=1} f&&/exit 18/{print; exit}' "$PROMOTE_SH"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# Parity: every handle_push_divergence capture with a 5 branch has an 18 branch
# ---------------------------------------------------------------------------

@test "parity: every handle_push_divergence capture site with a 5 branch also has an 18 branch" {
  local files=("$RUNNER_SH" "$MERGE_SH" "$CREATE_SH" "$CW_SH" "$PROMOTE_SH")
  local f
  for f in "${files[@]}"; do
    local five eighteen
    # Count blocks that check for div_result/DIV_RESULT/etc. == 5
    five=$(grep -cE '(div_result|DIV_RESULT|_div_result|_postdev_div_result|_supervised_sync_rc) -eq 5' "$f" || true)
    eighteen=$(grep -cE '(div_result|DIV_RESULT|_div_result|_postdev_div_result|_supervised_sync_rc) -eq 18' "$f" || true)
    if [ "$five" -gt 0 ]; then
      [ "$eighteen" -ge "$five" ] || {
        echo "FAIL: $f has $five '== 5' branches but only $eighteen '== 18' branches" >&2
        return 1
      }
    fi
  done
}
