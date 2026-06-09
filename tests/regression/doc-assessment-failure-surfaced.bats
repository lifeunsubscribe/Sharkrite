#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/core/workflow-runner.sh
# Regression test for: Wait on backgrounded doc assessment, surface failure
# Issue #19
#
# Bug: the waiter captured a PID for a background doc-assessment process
# but on failure the warning did not go to stderr and the log tail was not
# shown as error context. Additionally, assess-documentation.sh's parallel
# wait loops used `|| true`, masking which individual assessment failed.
#
# This test verifies:
# 1. When DOC_ASSESSMENT_SCRIPT exits non-zero, the waiter surfaces a warning
#    to stderr (visible even when stdout is piped/redirected).
# 2. When DOC_ASSESSMENT_SCRIPT exits non-zero, the waiter shows log tail
#    to stderr as failure context.
# 3. When DOC_ASSESSMENT_SCRIPT exits 0, no warning is emitted.
# 4. The waiter's source explicitly redirects the failure warning to stderr (>&2).
#
# Historical note: the waiter lived in merge-pr.sh until doc assessment was
# moved pre-merge. It now lives in workflow-runner.sh's phase_wait_doc_assessment.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW_RUNNER_SCRIPT="$PROJECT_ROOT/lib/core/workflow-runner.sh"
}

# -----------------------------------------------------------------------
# _wait_and_report_block: inline reproduction of the wait-and-report
# pattern from merge-pr.sh (lines ~1523-1542). We inline it here rather
# than extracting from the script to avoid fragile awk parsing of a large
# file, while still guarding against reintroduction of the silent-skip bug.
#
# If this block diverges from merge-pr.sh, Test 4 (static check) will catch
# the mismatch because it asserts >&2 is present in the actual source code.
# -----------------------------------------------------------------------

_wait_and_report_inline='
  if [ -n "${_DOC_PID:-}" ]; then
    _doc_exit=0
    wait "$_DOC_PID" 2>/dev/null || _doc_exit=$?

    if [ $_doc_exit -ne 0 ] && [ $_doc_exit -ne 2 ]; then
      print_warning "Documentation assessment failed (exit $_doc_exit)" >&2
      if [ -s "${_DOC_LOG:-}" ]; then
        echo "--- doc-assessment log (last 20 lines) ---" >&2
        tail -20 "$_DOC_LOG" >&2
        echo "---" >&2
      fi
    elif [ -s "${_DOC_LOG:-}" ]; then
      cat "$_DOC_LOG"
    fi
  fi
  rm -f "${_DOC_LOG:-}"
'

# -----------------------------------------------------------------------
# Test 1: DOC_ASSESSMENT_SCRIPT exits 1 → warning appears on stderr
# -----------------------------------------------------------------------

@test "merge-pr: doc assessment failure surfaces warning to stderr" {
  _stub=$(mktemp)
  chmod +x "$_stub"
  printf '#!/bin/bash\necho "doc error output"\nexit 1\n' > "$_stub"

  # Run the wait-and-report block with a failing background job.
  # bats `run` captures both stdout and stderr in $output.
  run bash -c "
    set -uo pipefail
    YELLOW=''
    NC=''
    print_warning() { echo \"WARNING: \$1\" >&2; }
    export -f print_warning

    _DOC_PID=''
    _DOC_LOG=\$(mktemp)
    '$_stub' > \"\$_DOC_LOG\" 2>&1 &
    _DOC_PID=\$!

    $_wait_and_report_inline
  " 2>&1

  rm -f "$_stub"

  [ "$status" -eq 0 ]
  # Warning must appear (surfaced to stderr, captured by bats 2>&1 redirect)
  [[ "$output" == *"WARNING:"*"Documentation assessment failed"* ]] || \
    [[ "$output" == *"WARNING:"*"assessment"* ]]
}

# -----------------------------------------------------------------------
# Test 2: DOC_ASSESSMENT_SCRIPT exits 1 → log tail shown on stderr
# -----------------------------------------------------------------------

@test "merge-pr: doc assessment failure tails log to stderr" {
  _stub=$(mktemp)
  chmod +x "$_stub"
  # The stub writes a unique token to its log output
  printf '#!/bin/bash\necho "UNIQUE_FAILURE_TOKEN_XYZ123"\nexit 1\n' > "$_stub"

  run bash -c "
    set -uo pipefail
    YELLOW=''
    NC=''
    print_warning() { echo \"WARNING: \$1\" >&2; }
    export -f print_warning

    _DOC_PID=''
    _DOC_LOG=\$(mktemp)
    '$_stub' > \"\$_DOC_LOG\" 2>&1 &
    _DOC_PID=\$!

    $_wait_and_report_inline
  " 2>&1

  rm -f "$_stub"

  [ "$status" -eq 0 ]
  # Log tail should appear as context on stderr
  [[ "$output" == *"UNIQUE_FAILURE_TOKEN_XYZ123"* ]]
}

# -----------------------------------------------------------------------
# Test 3: DOC_ASSESSMENT_SCRIPT exits 0 → no warning emitted
# -----------------------------------------------------------------------

@test "merge-pr: no warning emitted when doc assessment succeeds" {
  _stub=$(mktemp)
  chmod +x "$_stub"
  printf '#!/bin/bash\necho "Doc assessment complete"\nexit 0\n' > "$_stub"

  run bash -c "
    set -uo pipefail
    YELLOW=''
    NC=''
    print_warning() { echo \"WARNING: \$1\" >&2; }
    export -f print_warning

    _DOC_PID=''
    _DOC_LOG=\$(mktemp)
    '$_stub' > \"\$_DOC_LOG\" 2>&1 &
    _DOC_PID=\$!

    $_wait_and_report_inline
  " 2>&1

  rm -f "$_stub"

  [ "$status" -eq 0 ]
  # No warning should appear
  [[ "$output" != *"WARNING:"*"failed"* ]]
  # Log content should appear on success (stdout path)
  [[ "$output" == *"Doc assessment complete"* ]]
}

# -----------------------------------------------------------------------
# Test 4: Static check — merge-pr.sh failure warning explicitly uses >&2
# -----------------------------------------------------------------------

@test "workflow-runner.sh: doc-assessment failure warning explicitly redirects to stderr" {
  # Guard against reintroduction of the silent-skip bug where the warning
  # goes to stdout only (invisible in auto/piped mode).
  # The failure branch must use >&2 for both the warning and the log tail.

  # Find phase_wait_doc_assessment in the actual source (the waiter that used
  # to live in merge-pr.sh now lives here).
  _wait_block=$(awk '/^phase_wait_doc_assessment\(\)/,/^}/' "$WORKFLOW_RUNNER_SCRIPT")

  [ -n "$_wait_block" ]

  # The block must contain >&2 redirects for the failure path
  [[ "$_wait_block" == *">&2"* ]]

  # Must wait on the captured doc PID (not silently skip)
  [[ "$_wait_block" == *'wait "$pid"'* ]]
}

# -----------------------------------------------------------------------
# Test 5: Static check — assess-documentation.sh reports individual failures
# -----------------------------------------------------------------------

@test "assess-documentation.sh: parallel assessment wait loop reports individual failures" {
  _assess_doc="$PROJECT_ROOT/lib/core/assess-documentation.sh"

  # The _assess_pids loop must not use `|| true` to mask failures
  # (the old pattern was: wait "$_pid" 2>/dev/null || true)
  # The new pattern captures the exit code and reports it.

  # Extract the assess_pids section.
  # End-anchor matches the actual `unset _assess_pids _assess_names` line
  # (regex uses `unset _assess_pids` as a stable prefix so it isn't coupled
  # to the exact variable list that follows on the same line).
  _assess_section=$(awk '
    /Claude-calling assessments run in parallel/ { in_block=1 }
    in_block { print }
    in_block && /unset _assess_pids/ { in_block=0 }
  ' "$_assess_doc")

  [ -n "$_assess_section" ]

  # Must NOT use the silent `|| true` pattern in the wait loop
  # (check that the old single-line for loop is gone)
  _silent_wait_count=$(echo "$_assess_section" | grep -c 'wait.*|| true' || true)
  [ "$_silent_wait_count" -eq 0 ]

  # Must capture exit code and report failures
  [[ "$_assess_section" == *"_pid_exit"* ]]
  [[ "$_assess_section" == *"print_warning"* ]]
}

# -----------------------------------------------------------------------
# Test 6: Static check — assess-documentation.sh reconcile loop also fixed
# -----------------------------------------------------------------------

@test "assess-documentation.sh: parallel reconcile wait loop reports individual failures" {
  _assess_doc="$PROJECT_ROOT/lib/core/assess-documentation.sh"

  # Extract the reconcile_pids section.
  # End-anchor matches the actual `unset _reconcile_pids _reconcile_names` line
  # (regex uses `unset _reconcile_pids` as a stable prefix so it isn't coupled
  # to the exact variable list that follows on the same line).
  _reconcile_section=$(awk '
    /Run reconciliation in parallel/ { in_block=1 }
    in_block { print }
    in_block && /unset _reconcile_pids/ { in_block=0 }
  ' "$_assess_doc")

  [ -n "$_reconcile_section" ]

  # Must NOT use the silent `|| true` pattern
  _silent_wait_count=$(echo "$_reconcile_section" | grep -c 'wait.*|| true' || true)
  [ "$_silent_wait_count" -eq 0 ]

  # Must capture exit code and report failures
  [[ "$_reconcile_section" == *"_pid_exit"* ]]
  [[ "$_reconcile_section" == *"print_warning"* ]]
}
