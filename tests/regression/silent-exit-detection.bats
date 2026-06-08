#!/usr/bin/env bats
# Regression test for: Workflow exits silently after Phase 2 review post (#471)
#
# Bug history:
#   Issue #353's batch run on 2026-06-07 ended with this last log line:
#     [diag] 22:33:54 | REVIEW issue=353 critical=0 high=1 medium=1 low=1
#   ...and nothing after. No PHASE_FAILED, no WORKFLOW_COMPLETE, no
#   process surviving 13+ minutes later. The shell died silently between
#   Phase 2 (review posted) and Phase 3 (assessment fired) with no signal
#   to the operator or any future diagnostic.
#
# This test asserts the observability infrastructure that lets us localize
# the next silent exit:
#   1. workflow-runner.sh installs an EXIT trap that logs RITE_EXIT,
#      capturing CURRENT_PHASE / CURRENT_ISSUE / CURRENT_PR even when
#      no PHASE_FAILED diag fired.
#   2. workflow-runner.sh emits a PHASE_TRANSITION diag at every phase
#      boundary so the dead window is bounded between two timestamps.
#   3. batch-process-issues.sh emits its own RITE_EXIT diag for the
#      dispatcher process (the per-issue workflow-runner.sh has its own).

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
}

# ---------------------------------------------------------------------------
# Test: EXIT trap logs RITE_EXIT on silent exit (the #471 reproducer shape)
# ---------------------------------------------------------------------------
@test "EXIT trap: silent exit logs RITE_EXIT diag with captured phase state" {
  local log_file="${BATS_TEST_TMPDIR}/silent-exit.log"

  # Run a subprocess that:
  #   - sources workflow-runner.sh (loads _diag and _rite_atexit)
  #   - sets a known phase/issue context
  #   - calls setup_interrupt_handlers (installs the EXIT trap)
  #   - exit 1 with no PHASE_FAILED logged first
  #
  # The trap MUST fire and write RITE_EXIT to the log file even though
  # no error-path diag emitted before the silent exit.
  bash -c "
    set -euo pipefail
    export RITE_LOG_FILE='$log_file'
    source '${RITE_REPO_ROOT}/lib/core/workflow-runner.sh' 2>/dev/null
    CURRENT_PHASE='create-pr'
    CURRENT_ISSUE='353'
    CURRENT_PR='451'
    setup_interrupt_handlers
    # Simulate the #471 silent-exit pattern: shell dies after Phase 2 with
    # no PHASE_FAILED diag and no graceful completion.
    exit 1
  " || true

  # Trap must have fired and written to the log
  [ -f "$log_file" ]
  grep -q 'RITE_EXIT' "$log_file"
  grep -q 'code=1' "$log_file"
  grep -q 'phase=create-pr' "$log_file"
  grep -q 'issue=353' "$log_file"
}

# ---------------------------------------------------------------------------
# Test: EXIT trap logs RITE_EXIT on exit 0 (normal completion path)
# ---------------------------------------------------------------------------
@test "EXIT trap: normal completion also logs RITE_EXIT diag" {
  local log_file="${BATS_TEST_TMPDIR}/normal-exit.log"

  bash -c "
    set -euo pipefail
    export RITE_LOG_FILE='$log_file'
    source '${RITE_REPO_ROOT}/lib/core/workflow-runner.sh' 2>/dev/null
    CURRENT_PHASE='completion'
    CURRENT_ISSUE='100'
    setup_interrupt_handlers
    exit 0
  "

  [ -f "$log_file" ]
  grep -q 'RITE_EXIT' "$log_file"
  grep -q 'code=0' "$log_file"
  grep -q 'phase=completion' "$log_file"
}

# ---------------------------------------------------------------------------
# Test: EXIT trap survives set -e firing inside a function
# ---------------------------------------------------------------------------
@test "EXIT trap: set -e abort still triggers RITE_EXIT diag" {
  local log_file="${BATS_TEST_TMPDIR}/set-e-exit.log"

  bash -c "
    set -euo pipefail
    export RITE_LOG_FILE='$log_file'
    source '${RITE_REPO_ROOT}/lib/core/workflow-runner.sh' 2>/dev/null
    CURRENT_PHASE='assess-resolve'
    CURRENT_ISSUE='200'
    setup_interrupt_handlers

    # set -e propagation from a non-zero command in a function — this is the
    # \"shell dies between phases\" class of silent exit that motivated #471.
    _silent_failer() {
      false  # set -e propagates this
      echo 'should never print'
    }
    _silent_failer
  " || true

  [ -f "$log_file" ]
  grep -q 'RITE_EXIT' "$log_file"
  grep -q 'phase=assess-resolve' "$log_file"
}

# ---------------------------------------------------------------------------
# Test: PHASE_TRANSITION diags are wired at every phase boundary
#
# Static-source check: the diag lines must exist immediately before each
# CURRENT_PHASE assignment in the run_workflow phase block. If a future
# refactor drops one, the silent-exit window between that phase and the
# next stops being localizable in the log.
# ---------------------------------------------------------------------------
@test "PHASE_TRANSITION diags exist for every phase boundary" {
  local wf="${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"

  # Each of these phases must have a PHASE_TRANSITION diag near its
  # CURRENT_PHASE assignment in run_workflow().
  for phase in pre-start claude-workflow create-pr assess-resolve merge completion; do
    run grep -F "PHASE_TRANSITION" "$wf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"to=$phase"* ]] || {
      echo "Missing PHASE_TRANSITION diag for phase: $phase" >&2
      false
    }
  done
}

# ---------------------------------------------------------------------------
# Test: batch-process-issues.sh EXIT trap also logs RITE_EXIT
# ---------------------------------------------------------------------------
@test "batch EXIT trap: silent exit logs RITE_EXIT mode=batch" {
  local log_file="${BATS_TEST_TMPDIR}/batch-exit.log"

  bash -c "
    set -euo pipefail
    export RITE_LOG_FILE='$log_file'
    # Source logging and define the trap inline (mirrors batch-process-issues.sh).
    # We don't source batch-process-issues.sh directly because its top-level body
    # parses args and exits immediately when none are provided.
    source '${RITE_REPO_ROOT}/lib/utils/logging.sh'
    ISSUE_NUM=357
    _cleanup_batch_session() {
      local rc=\$?
      if declare -f _diag >/dev/null 2>&1; then
        _diag \"RITE_EXIT code=\${rc} mode=batch current_issue=\${ISSUE_NUM:-unknown}\"
      fi
    }
    trap '_cleanup_batch_session' EXIT
    exit 7
  " || true

  [ -f "$log_file" ]
  grep -q 'RITE_EXIT' "$log_file"
  grep -q 'code=7' "$log_file"
  grep -q 'mode=batch' "$log_file"
  grep -q 'current_issue=357' "$log_file"
}

# ---------------------------------------------------------------------------
# Test: the exact batch trap definition is wired into batch-process-issues.sh
#
# This catches the case where a future refactor removes RITE_EXIT from the
# batch cleanup function — the previous test only validates the trap shape,
# not that it's actually installed in the dispatcher.
# ---------------------------------------------------------------------------
@test "batch dispatcher: _cleanup_batch_session emits RITE_EXIT" {
  local batch="${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  run grep -F 'RITE_EXIT' "$batch"
  [ "$status" -eq 0 ]
  [[ "$output" == *'mode=batch'* ]]
}
