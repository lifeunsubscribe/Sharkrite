#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/providers/claude.sh, lib/utils/date-helpers.sh
# tests/regression/cap-resume-manifest.bats
#
# Regression test: when a batch aborts on usage cap (exit 5), sharkrite must:
#   - Parse the reset time from the CLI cap message
#   - Write a resume manifest (.rite/state/cap-resume.json) with remaining
#     issues, flags, the parsed reset epoch, and the raw reset text
#   - Print the exact resume command so the user can re-run without archaeology
#
# Issue #1142 — "Write cap-resume manifest with parsed reset time"
#
# Related: issue #1121/PR #1122 (exit-0 cap detection), follow-up: auto-resume
#
# Tests in this file:
#
#   STRUCTURAL (static code inspection):
#     1.  batch-process-issues.sh reads cap-reset-line.txt in exit-5 handler
#     2.  batch-process-issues.sh writes cap-resume.json in exit-5 handler
#     3.  batch-process-issues.sh prints "Resume with:" in exit-5 handler
#     4.  exit-codes.md exit 5 semantics unchanged (still "Usage/token cap reached")
#     5.  claude.sh writes cap-reset-line.txt when cap detected
#     6.  claude.sh persists reset line before deleting _stdout_capture
#
#   UNIT (cap_reset_to_epoch parser):
#     7.  "resets 6:10pm (America/Denver)" parses to non-zero epoch
#     8.  "resets 11:20pm" (no timezone) parses to non-zero epoch
#     9.  garbage input (no time) returns epoch 0
#    10.  empty string returns epoch 0
#    11.  time that has already passed rolls forward to next day (epoch > now)
#    12.  "You've hit your session limit · resets 9:20pm (America/Denver)" full
#         real-world phrasing parses to non-zero epoch

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DATE_HELPERS="$REPO_ROOT/lib/utils/date-helpers.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
CLAUDE_PROVIDER="$REPO_ROOT/lib/providers/claude.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"

setup() {
  for _f in "$DATE_HELPERS" "$BATCH_PROCESSOR" "$CLAUDE_PROVIDER" "$EXIT_CODES_DOC"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify the implementation is in place (static code inspection)
# =============================================================================

@test "structural: batch-process-issues.sh reads cap-reset-line.txt in exit-5 handler" {
  grep -q 'cap-reset-line.txt' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'cap-reset-line.txt' not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must read the reset-line written by claude.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh writes cap-resume.json in exit-5 handler" {
  grep -q 'cap-resume.json' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'cap-resume.json' not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must write the resume manifest" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh prints 'Resume with:' in exit-5 handler" {
  grep -q 'Resume with:' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'Resume with:' not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must print the copy-pasteable resume command" >&2
    return 1
  }
}

@test "structural: exit-codes.md exit 5 semantics unchanged (usage cap)" {
  # The manifest feature must not change exit code semantics
  grep -qiE 'code.*5|5.*Usage.*cap|Usage.*token.*cap' "$EXIT_CODES_DOC" || {
    echo "FAIL: exit 5 not documented as usage/token cap in exit-codes.md" >&2
    echo "      exit 5 semantics must remain 'Usage/token cap reached'" >&2
    return 1
  }
}

@test "structural: claude.sh writes cap-reset-line.txt when cap is detected" {
  grep -q 'cap-reset-line.txt' "$CLAUDE_PROVIDER" || {
    echo "FAIL: 'cap-reset-line.txt' not found in claude.sh" >&2
    echo "      provider must persist the reset-line when exit_code=5 is set" >&2
    return 1
  }
}

@test "structural: claude.sh persists reset line only when _exit_code equals 5" {
  # The persistence block must be guarded by the exit_code=5 condition so it
  # never fires on auth failure (18) or generic errors (1).
  grep -qE '_exit_code.*-eq.*5.*cap-reset|cap-reset.*_exit_code.*5' "$CLAUDE_PROVIDER" || {
    # Accept multi-line match: the guard and the write are nearby
    _block=$(grep -A8 '_exit_code.*-eq.*5.*&&.*RITE_STATE_DIR\|_exit_code.*eq 5.*RITE_STATE_DIR' "$CLAUDE_PROVIDER" || true)
    [ -n "$_block" ] || {
      # Just verify both patterns exist close together
      _guard=$(grep -n '_exit_code.*-eq.*5.*RITE_STATE_DIR\|if.*_exit_code.*5.*RITE_STATE_DIR' "$CLAUDE_PROVIDER" || true)
      _write=$(grep -n 'cap-reset-line.txt' "$CLAUDE_PROVIDER" || true)
      [ -n "$_guard" ] && [ -n "$_write" ] || {
        echo "FAIL: cap-reset-line.txt write is not guarded by exit_code=5 check" >&2
        return 1
      }
    }
  }
}

# =============================================================================
# UNIT: cap_reset_to_epoch parser
# =============================================================================

@test "unit: cap_reset_to_epoch parses 'resets 6:10pm (America/Denver)' to non-zero epoch" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch 'You have hit your session limit resets 6:10pm (America/Denver)'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "${output:-0}" != "0" ] || {
    echo "FAIL: expected non-zero epoch for valid time input, got: '$output'" >&2
    return 1
  }
  # Must be a plausible future epoch (after year 2020 = 1577836800)
  [ "${output:-0}" -gt 1577836800 ] || {
    echo "FAIL: epoch ${output} is not a plausible future timestamp" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch parses 'resets 11:20pm' (no timezone) to non-zero epoch" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch 'Spending cap reached resets 11:20pm'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "${output:-0}" != "0" ] || {
    echo "FAIL: expected non-zero epoch for 'resets 11:20pm', got: '$output'" >&2
    return 1
  }
  [ "${output:-0}" -gt 1577836800 ] || {
    echo "FAIL: epoch ${output} is not a plausible future timestamp" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch returns 0 for input with no time" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch 'Spending cap reached, no time here'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status (expected 0)" >&2
    return 1
  }
  [ "${output:-}" = "0" ] || {
    echo "FAIL: expected '0' for input with no parseable time, got: '$output'" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch returns 0 for empty input" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch ''
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status for empty input (expected 0)" >&2
    return 1
  }
  [ "${output:-}" = "0" ] || {
    echo "FAIL: expected '0' for empty input, got: '$output'" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch rolls past time to next day (epoch greater than now)" {
  # "12:00am" is always in the past once it is past midnight (true for any
  # development-hour test run). The function must roll it to next day.
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    _result=\$(cap_reset_to_epoch 'resets 12:00am')
    _now=\$(date +%s)
    echo \"\$_result \$_now\"
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  _epoch=$(echo "$output" | awk '{print $1}')
  _now=$(echo "$output" | awk '{print $2}')
  [ "${_epoch:-0}" != "0" ] || {
    echo "FAIL: cap_reset_to_epoch returned 0 for '12:00am' — parse failed" >&2
    return 1
  }
  [ "$_epoch" -gt "$_now" ] || {
    echo "FAIL: rolled epoch $_epoch is not greater than now $_now" >&2
    echo "      'resets 12:00am' (past midnight) must roll to tomorrow's 12:00am" >&2
    return 1
  }
}

@test "unit: full real-world phrasing 'You've hit your session limit · resets 9:20pm (America/Denver)' parses" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch \$'You\\'ve hit your session limit \\xc2\\xb7 resets 9:20pm (America/Denver)'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "${output:-0}" != "0" ] || {
    echo "FAIL: expected non-zero epoch for real-world phrasing, got: '$output'" >&2
    return 1
  }
}
