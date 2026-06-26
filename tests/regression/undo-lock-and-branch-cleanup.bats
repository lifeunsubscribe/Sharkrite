#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/undo-workflow.sh
# Regression: `rite --undo N` must comprehensively clean its artifacts.
#
# Live gaps (#649): after `rite --undo 649`, two orphans survived —
#   1. the per-issue lock dir .rite/locks/issue-649.lock (undo's state-cleanup
#      block was gated on SESSION_STATE_EXISTS, but a run that dies early leaves
#      the lock with NO session-state file), and
#   2. the remote branch (the delete swallowed errors with `2>/dev/null` and
#      reported "already deleted or not found" while the branch still existed).
#
# undo-workflow.sh is a top-level script (runs on source), so these mirror the
# existing snippet-extraction pattern (see undo-workflow-bash-3-2-compat.bats)
# plus structural assertions that tie the behaviour to the real source.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  TEST_DIR="${BATS_TEST_TMPDIR}/undo-cleanup"; mkdir -p "$TEST_DIR"; export TEST_DIR
}
teardown() { rm -rf "$TEST_DIR"; }

@test "undo removes the issue lock dir even with NO session-state file (#649)" {
  # Reproduces the section-3.6 cleanup decision: the lock is cleaned when present,
  # independent of SESSION_STATE_EXISTS.
  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=649
    SESSION_STATE_EXISTS=false                       # run died early — no state file
    RITE_LOCK_DIR="'"$TEST_DIR"'/locks"
    _undo_lock_dir="${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock"
    mkdir -p "$_undo_lock_dir"; echo 12345 > "$_undo_lock_dir/pid"   # orphan lock

    if [ "$SESSION_STATE_EXISTS" = true ] || [ -d "$_undo_lock_dir" ]; then
      if [ -d "$_undo_lock_dir" ]; then rm -rf "$_undo_lock_dir"; fi
    fi

    [ -d "$_undo_lock_dir" ] && { echo "FAIL: lock survived"; exit 1; }
    echo "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "undo source: lock cleanup is reachable when session state is absent" {
  # Guard against a regression that re-gates the lock removal solely under the
  # session-state-file check (the original #649 gap).
  run grep -E 'SESSION_STATE_EXISTS" = true \] \|\| \[ -d "\$_undo_lock_dir"' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
  run grep -E 'rm -rf "\$_undo_lock_dir"' "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "undo source: remote-branch delete verifies the result (no silent swallow)" {
  # The delete must re-check existence and warn loudly on failure, not report
  # "already deleted" while the branch survives.
  run grep -E 'git ls-remote --heads origin "\$BRANCH_NAME"' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
  run grep -E 'Failed to delete remote branch' "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}
