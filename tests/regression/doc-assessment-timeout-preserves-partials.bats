#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/core/workflow-runner.sh
# Regression test: on doc-assessment timeout, completed sub-assessments are preserved
# Issue #341
#
# Bug: when the watchdog fired, all in-flight doc assessment work was
# discarded (the background process was killed and the log file was deleted). Even
# sub-assessments that completed before the kill had their doc file writes survive
# on disk, but the user saw "continuing without doc updates" with no indication
# that partial work was preserved.
#
# Fix: each sub-assessment writes "partial_complete:<name>" to stdout (captured in
# the log file) when it completes a doc update. The watchdog reads the log
# on timeout to count and report completed sub-assessments. Completed doc files
# remain on disk - only the in-flight ones are lost.
#
# Historical note: this logic originally lived in merge-pr.sh (post-merge spawn).
# It now lives in workflow-runner.sh's phase_wait_doc_assessment, because doc
# assessment runs pre-merge so Layer 2 commits ride the squash merge.
#
# Test strategy:
# 1. Watchdog fires with 2 completed sub-assessments: output reports "2 completed".
# 2. Watchdog fires with 0 completed sub-assessments: output reports "no progress".
# 3. Watchdog fires with all 4 completed: output reports "4 completed" (all preserved).
# 4. Normal completion (no timeout): partial_complete lines in log do not cause errors.
# 5. Static check: merge-pr.sh reads partial_complete: from _DOC_LOG on timeout.
# 6. Static check: assess-documentation.sh sub-assessments emit partial_complete: lines.
# 7. Static check: default timeout is 300s (not the old 180s).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW_RUNNER_SCRIPT="$PROJECT_ROOT/lib/core/workflow-runner.sh"
  ASSESS_DOC="$PROJECT_ROOT/lib/core/assess-documentation.sh"
  export PROJECT_ROOT WORKFLOW_RUNNER_SCRIPT ASSESS_DOC

  # Write the watchdog block as a helper script to avoid quoting nightmares.
  # This mirrors the actual watchdog section from merge-pr.sh.
  _watchdog_helper="$(mktemp)"
  cat > "$_watchdog_helper" << 'WATCHDOG_EOF'
#!/bin/bash
set -euo pipefail
# Args: <doc_log> <timeout> <mode>
#   <mode> = N            -> spawn a child that writes N partial_complete: lines
#                            then hangs (sleep 200) so the watchdog times it out.
#   <mode> = normal:N     -> spawn a child that writes N partial_complete: lines
#                            plus an "Internal:" line then exits 0 (success path).
# The child MUST be spawned by this helper process so that `wait "$_DOC_PID"`
# operates on a real child (cross-process wait fails on bash 5.x — see triage
# for issue #341). This mirrors production: phase_spawn_doc_assessment and
# phase_wait_doc_assessment both run in the same shell.
_DOC_LOG="$1"
export RITE_DOC_ASSESSMENT_TIMEOUT="$2"
_MODE="$3"

_doc_exit=0
_doc_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"

if [ "${_MODE#normal:}" != "$_MODE" ]; then
  # normal:N -> success path: write N partials + an Internal: line, then exit 0.
  _N="${_MODE#normal:}"
  ( i=0; while [ "$i" -lt "$_N" ]; do printf 'partial_complete:item%d\n' "$i"; i=$((i+1)); done
    echo 'Internal: security checkmark  api checkmark'
  ) > "$_DOC_LOG" 2>&1 &
  _DOC_PID=$!
else
  # N -> timeout path: write N partials then hang so the watchdog kills it.
  _N="$_MODE"
  ( i=0; while [ "$i" -lt "$_N" ]; do printf 'partial_complete:item%d\n' "$i"; i=$((i+1)); done
    sleep 200
  ) > "$_DOC_LOG" 2>&1 &
  _DOC_PID=$!
fi

( sleep "$_doc_timeout" && kill -TERM "$_DOC_PID" 2>/dev/null ) &
_doc_watchdog_pid=$!

wait "$_DOC_PID" 2>/dev/null || _doc_exit=$?

kill -TERM "$_doc_watchdog_pid" 2>/dev/null || true
wait "$_doc_watchdog_pid" 2>/dev/null || true

if [ "$_doc_exit" -eq 143 ] || [ "$_doc_exit" -eq 137 ]; then
  _completed_partials=0
  if [ -s "${_DOC_LOG:-}" ]; then
    _completed_partials=$(grep -c "^partial_complete:" "$_DOC_LOG" 2>/dev/null || true)
  fi
  if [ "$_completed_partials" -gt 0 ]; then
    echo "WARNING: Documentation assessment timed out after ${_doc_timeout}s -- preserving $_completed_partials completed sub-assessment(s)" >&2
    grep "^partial_complete:" "$_DOC_LOG" 2>/dev/null | sed 's/^partial_complete:/  checkmark /' >&2 || true
  else
    echo "WARNING: Documentation assessment timed out after ${_doc_timeout}s -- no sub-assessments completed before timeout" >&2
  fi
elif [ "$_doc_exit" -ne 0 ] && [ "$_doc_exit" -ne 2 ]; then
  echo "WARNING: Documentation assessment failed (exit $_doc_exit)" >&2
else
  [ -s "${_DOC_LOG:-/dev/null}" ] && cat "$_DOC_LOG"
fi

rm -f "${_DOC_LOG:-}"
echo "merge_tail_completed"
WATCHDOG_EOF
  chmod +x "$_watchdog_helper"
  export _watchdog_helper
}

teardown() {
  rm -f "${_watchdog_helper:-}"
}

# ---------------------------------------------------------------------------
# Test 1: Timeout fires with 2 completed sub-assessments
# ---------------------------------------------------------------------------

@test "merge-pr: timeout with 2 completed partials reports 2 preserved" {
  # Helper spawns a child that writes 2 partial_complete: lines then hangs,
  # so the 3s watchdog times it out -> 2 preserved.
  run bash "$_watchdog_helper" "$(mktemp)" "3" "2"

  [ "$status" -eq 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"preserving 2 completed"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: Timeout fires with 0 completed sub-assessments
# ---------------------------------------------------------------------------

@test "merge-pr: timeout with 0 completed partials reports no progress" {
  # Helper spawns a child that writes 0 partials then hangs, so the 3s
  # watchdog times it out -> no sub-assessments completed.
  run bash "$_watchdog_helper" "$(mktemp)" "3" "0"

  [ "$status" -eq 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"no sub-assessments completed"* ]]
  [[ "$output" != *"preserving"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: Timeout fires with all 4 completed
# ---------------------------------------------------------------------------

@test "merge-pr: timeout with 4 completed partials reports 4 preserved" {
  # Helper spawns a child that writes 4 partial_complete: lines then hangs,
  # so the 3s watchdog times it out -> 4 preserved.
  run bash "$_watchdog_helper" "$(mktemp)" "3" "4"

  [ "$status" -eq 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"preserving 4 completed"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Normal completion -- partial_complete lines in log cause no errors
# ---------------------------------------------------------------------------

@test "merge-pr: normal completion with partial_complete lines in log works fine" {
  # normal:2 -> helper spawns a child that writes 2 partials + an Internal:
  # line then exits 0. With a 30s timeout the watchdog never fires.
  run bash "$_watchdog_helper" "$(mktemp)" "30" "normal:2"

  [ "$status" -eq 0 ]
  # No timeout warning should be emitted
  [[ "$output" != *"timed out"* ]]
  # Normal output (the doc log) should be shown
  [[ "$output" == *"Internal:"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Static check -- merge-pr.sh reads partial_complete: from _DOC_LOG on timeout
# ---------------------------------------------------------------------------

@test "workflow-runner.sh: partial_complete: harvest present in timeout branch" {
  local timeout_block
  # The waiter is in phase_wait_doc_assessment now (moved from merge-pr.sh).
  # The new code uses `completed=0` (no leading underscore) — match the
  # current naming.
  timeout_block=$(grep -A 20 -E 'local completed=0|_completed_partials=0' "$WORKFLOW_RUNNER_SCRIPT" || true)

  [ -n "$timeout_block" ]

  # Must grep for partial_complete: marker
  [[ "$timeout_block" == *"partial_complete:"* ]]

  # Must distinguish preserved vs no-progress messages
  [[ "$timeout_block" == *"preserving"* ]]
  [[ "$timeout_block" == *"no sub-assessments completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 6: Static check -- assess-documentation.sh sub-assessments emit partial_complete:
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: sub-assessments emit partial_complete: on completion" {
  local partial_count
  partial_count=$(grep -c 'echo "partial_complete:' "$ASSESS_DOC" || true)
  # At least security, architecture, api, adr -- 4 sub-assessments
  [ "$partial_count" -ge 4 ]
}

# ---------------------------------------------------------------------------
# Test 7: Static check -- default timeout is 300s (not the old 180s)
# ---------------------------------------------------------------------------

@test "workflow-runner.sh: default RITE_DOC_ASSESSMENT_TIMEOUT is 300 (not 180)" {
  local default_timeout
  default_timeout=$(grep 'RITE_DOC_ASSESSMENT_TIMEOUT:-' "$WORKFLOW_RUNNER_SCRIPT" | grep -oE '[0-9]+' | head -1 || true)
  [ "$default_timeout" = "300" ]
}
