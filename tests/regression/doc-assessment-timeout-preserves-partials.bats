#!/usr/bin/env bats
# Regression test: on doc-assessment timeout, completed sub-assessments are preserved
# Issue #341
#
# Bug: when the merge-pr.sh watchdog fired, all in-flight doc assessment work was
# discarded (the background process was killed and _DOC_LOG was deleted). Even
# sub-assessments that completed before the kill had their doc file writes survive
# on disk, but the user saw "continuing without doc updates" with no indication
# that partial work was preserved.
#
# Fix: each sub-assessment writes "partial_complete:<name>" to stdout (captured in
# _DOC_LOG) when it completes a doc update. The merge-pr.sh watchdog reads _DOC_LOG
# on timeout to count and report completed sub-assessments. Completed doc files
# remain on disk - only the in-flight ones are lost.
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
  MERGE_PR_SCRIPT="$PROJECT_ROOT/lib/core/merge-pr.sh"
  ASSESS_DOC="$PROJECT_ROOT/lib/core/assess-documentation.sh"
  export PROJECT_ROOT MERGE_PR_SCRIPT ASSESS_DOC

  # Write the watchdog block as a helper script to avoid quoting nightmares.
  # This mirrors the actual watchdog section from merge-pr.sh.
  _watchdog_helper="$(mktemp)"
  cat > "$_watchdog_helper" << 'WATCHDOG_EOF'
#!/bin/bash
set -euo pipefail
# Args: <doc_pid> <doc_log> <timeout>
_DOC_PID="$1"
_DOC_LOG="$2"
export RITE_DOC_ASSESSMENT_TIMEOUT="$3"

_doc_exit=0
_doc_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"

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
  # Start a subprocess that writes 2 partial_complete: lines then hangs
  local _DOC_LOG
  _DOC_LOG=$(mktemp)
  ( printf 'partial_complete:security\npartial_complete:architecture\n'
    sleep 200
  ) > "$_DOC_LOG" 2>&1 &
  local _DOC_PID=$!

  run bash "$_watchdog_helper" "$_DOC_PID" "$_DOC_LOG" "3"

  [ "$status" -eq 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"preserving 2 completed"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: Timeout fires with 0 completed sub-assessments
# ---------------------------------------------------------------------------

@test "merge-pr: timeout with 0 completed partials reports no progress" {
  local _DOC_LOG
  _DOC_LOG=$(mktemp)
  # Subprocess hangs immediately (no partials written)
  sleep 200 > "$_DOC_LOG" 2>&1 &
  local _DOC_PID=$!

  run bash "$_watchdog_helper" "$_DOC_PID" "$_DOC_LOG" "3"

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
  local _DOC_LOG
  _DOC_LOG=$(mktemp)
  ( printf 'partial_complete:security\npartial_complete:architecture\npartial_complete:api\npartial_complete:adr\n'
    sleep 200
  ) > "$_DOC_LOG" 2>&1 &
  local _DOC_PID=$!

  run bash "$_watchdog_helper" "$_DOC_PID" "$_DOC_LOG" "3"

  [ "$status" -eq 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"preserving 4 completed"* ]]
  [[ "$output" == *"merge_tail_completed"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Normal completion -- partial_complete lines in log cause no errors
# ---------------------------------------------------------------------------

@test "merge-pr: normal completion with partial_complete lines in log works fine" {
  local _DOC_LOG
  _DOC_LOG=$(mktemp)
  ( printf 'partial_complete:security\npartial_complete:api\n'
    echo 'Internal: security checkmark  api checkmark'
  ) > "$_DOC_LOG" 2>&1 &
  local _DOC_PID=$!

  run bash "$_watchdog_helper" "$_DOC_PID" "$_DOC_LOG" "30"

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

@test "merge-pr.sh: partial_complete: harvest present in timeout branch" {
  local timeout_block
  timeout_block=$(grep -A 20 '_completed_partials=0' "$MERGE_PR_SCRIPT" || true)

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

@test "merge-pr.sh: default RITE_DOC_ASSESSMENT_TIMEOUT is 300 (not 180)" {
  local default_timeout
  default_timeout=$(grep 'RITE_DOC_ASSESSMENT_TIMEOUT:-' "$MERGE_PR_SCRIPT" | grep -oE '[0-9]+' | head -1 || true)
  [ "$default_timeout" = "300" ]
}
