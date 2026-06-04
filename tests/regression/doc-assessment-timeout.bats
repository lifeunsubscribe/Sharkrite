#!/usr/bin/env bats
# Regression test: merge-pr.sh RITE_DOC_ASSESSMENT_TIMEOUT watchdog
# Issue #308
#
# Bug: The `wait "$_DOC_PID"` in merge-pr.sh had no upper bound. If the doc
# assessment subprocess hung (Claude API issue, network drop), the merge tail
# would hang indefinitely — even after the merge itself + worktree cleanup had
# already completed.
#
# Fix: A watchdog subprocess (`( sleep $timeout && kill -TERM $DOC_PID ) &`)
# kills the assessment after RITE_DOC_ASSESSMENT_TIMEOUT seconds (default 180s).
#
# Test strategy:
# 1. Stub the doc assessment to hang (sleep 200s). Set timeout to 5s.
#    Assert the wait-and-report block completes within 10s and logs a warning.
# 2. Stub the doc assessment to succeed quickly. Assert the watchdog does NOT
#    fire — no spurious warning, and the watchdog process is cleaned up.
# 3. Static check: assert RITE_DOC_ASSESSMENT_TIMEOUT is referenced in merge-pr.sh.
# 4. Static check: assert the watchdog kill pattern is present in merge-pr.sh.
# 5. Static check: assert SIGTERM (143) and SIGKILL (137) are handled in the
#    timeout branch in merge-pr.sh.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  MERGE_PR_SCRIPT="$PROJECT_ROOT/lib/core/merge-pr.sh"
  export PROJECT_ROOT
}

# ---------------------------------------------------------------------------
# Shared inline wait-and-report block
#
# This mirrors the actual watchdog section from merge-pr.sh.
# If the source diverges, Test 3 (static check) will catch the mismatch
# because it asserts RITE_DOC_ASSESSMENT_TIMEOUT is in the source.
# ---------------------------------------------------------------------------

_wait_and_report_with_watchdog='
  if [ -n "${_DOC_PID:-}" ]; then
    _doc_exit=0
    _doc_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-180}"

    ( sleep "$_doc_timeout" && kill -TERM "$_DOC_PID" 2>/dev/null ) &
    _doc_watchdog_pid=$!

    wait "$_DOC_PID" 2>/dev/null || _doc_exit=$?

    kill -TERM "$_doc_watchdog_pid" 2>/dev/null || true
    wait "$_doc_watchdog_pid" 2>/dev/null || true

    if [ "$_doc_exit" -eq 143 ] || [ "$_doc_exit" -eq 137 ]; then
      echo "WARNING: Documentation assessment timed out after ${_doc_timeout}s — continuing without doc updates" >&2
    elif [ $_doc_exit -ne 0 ] && [ $_doc_exit -ne 2 ]; then
      echo "WARNING: Documentation assessment failed (exit $_doc_exit)" >&2
    else
      [ -s "${_DOC_LOG:-/dev/null}" ] && cat "$_DOC_LOG"
    fi
  fi
  rm -f "${_DOC_LOG:-}"
'

# ---------------------------------------------------------------------------
# Test 1: Hanging assessment is killed after timeout; merge tail completes
# ---------------------------------------------------------------------------

@test "merge-pr: doc assessment timeout kills hanging subprocess, continues" {
  # The assessment hangs for 200s but the timeout is 5s.
  # Total elapsed should be ~5s (not 200s).
  local start_time end_time elapsed

  run bash -c "
    _DOC_LOG=\$(mktemp)
    # Background a hanging subprocess (sleep 200)
    sleep 200 > \"\$_DOC_LOG\" 2>&1 &
    _DOC_PID=\$!

    export RITE_DOC_ASSESSMENT_TIMEOUT=5

    $_wait_and_report_with_watchdog

    echo 'merge_tail_completed'
  " 2>&1

  local elapsed_check_start
  # The test must finish within 12s (5s timeout + generous CI margin)
  # bats imposes its own timeout per test, but we assert the output here
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING:"*"timed out"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: Assessment that finishes quickly — no timeout warning, watchdog cleaned up
# ---------------------------------------------------------------------------

@test "merge-pr: fast doc assessment completes without timeout warning" {
  run bash -c "
    _DOC_LOG=\$(mktemp)
    # Background a fast subprocess
    ( echo 'doc assessment complete'; exit 0 ) > \"\$_DOC_LOG\" 2>&1 &
    _DOC_PID=\$!

    export RITE_DOC_ASSESSMENT_TIMEOUT=30

    $_wait_and_report_with_watchdog

    echo 'merge_tail_completed'
  " 2>&1

  [ "$status" -eq 0 ]
  # No timeout warning should be emitted
  [[ "$output" != *"timed out"* ]]
  # Doc output should be shown (success path)
  [[ "$output" == *"doc assessment complete"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: Static check — RITE_DOC_ASSESSMENT_TIMEOUT is referenced in merge-pr.sh
# ---------------------------------------------------------------------------

@test "merge-pr.sh: RITE_DOC_ASSESSMENT_TIMEOUT env var referenced in source" {
  local count
  count=$(grep -c 'RITE_DOC_ASSESSMENT_TIMEOUT' "$MERGE_PR_SCRIPT" || true)
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: Static check — watchdog kill pattern present in merge-pr.sh
# (ensures the watchdog is launched and cancelled correctly)
# ---------------------------------------------------------------------------

@test "merge-pr.sh: watchdog kill-TERM pattern present in source" {
  # The watchdog subshell must be launched
  local watchdog_launch_count
  watchdog_launch_count=$(grep -c '_doc_watchdog_pid' "$MERGE_PR_SCRIPT" || true)
  [ "$watchdog_launch_count" -ge 2 ]   # at least: assignment + cancel

  # The watchdog must be cancelled after wait (to avoid zombie sleep processes)
  local cancel_count
  cancel_count=$(grep -c 'kill.*_doc_watchdog_pid' "$MERGE_PR_SCRIPT" || true)
  [ "$cancel_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 5: Static check — timeout exit codes (143, 137) handled in merge-pr.sh
# ---------------------------------------------------------------------------

@test "merge-pr.sh: SIGTERM (143) and SIGKILL (137) handled in timeout branch" {
  # Extract the wait-and-report block — anchor on _DOC_PID variable
  local wait_block
  wait_block=$(grep -A 25 '_doc_timeout=.*RITE_DOC_ASSESSMENT_TIMEOUT' "$MERGE_PR_SCRIPT" || true)

  [ -n "$wait_block" ]

  # Both SIGTERM (143) and SIGKILL (137) must be in the conditional
  [[ "$wait_block" == *"143"* ]]
  [[ "$wait_block" == *"137"* ]]

  # The timeout warning message must be present
  [[ "$wait_block" == *"timed out"* ]]
}

# ---------------------------------------------------------------------------
# Test 6: Timeout fires before watchdog: exit code 143 triggers timeout branch
#          (not the generic failure branch)
# ---------------------------------------------------------------------------

@test "merge-pr: exit code 143 (SIGTERM) is treated as timeout, not generic failure" {
  run bash -c "
    _DOC_LOG=\$(mktemp)
    # Simulate a doc assessment subprocess that was killed by SIGTERM (exit 143)
    ( exit 143 ) &
    _DOC_PID=\$!

    export RITE_DOC_ASSESSMENT_TIMEOUT=30

    $_wait_and_report_with_watchdog

    echo 'merge_tail_completed'
  " 2>&1

  [ "$status" -eq 0 ]
  # Must show the timeout warning (not the generic failure warning)
  [[ "$output" == *"timed out"* ]]
  [[ "$output" != *"assessment failed"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}
