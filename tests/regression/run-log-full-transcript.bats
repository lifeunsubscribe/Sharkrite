#!/usr/bin/env bats
# Regression test for: Run log file missing actual terminal output (#463)
#
# Bug: .rite/logs/rite-*.log only captured structured timing/diag metadata,
# not the actual terminal output (Claude tool calls, bats per-test output,
# make check output). The old nested process-substitution tee had a race
# condition and test-gate.sh explicitly captured subprocess output to temp
# files without also routing it to stdout.
#
# Fix:
#   1. bin/rite: FIFO-based tee — strip_ansi reader stays alive until the write
#      end closes, eliminating the truncation race.
#   2. test-gate.sh: tee make/bats output to stdout in addition to the temp
#      file, so the parent's transcript tee captures it.
#
# This test verifies:
#   1. Full-transcript: subprocess stdout appears in the log file
#   2. ANSI-stripped: log file contains no escape sequences
#   3. No-double-diag: direct-write metadata (_diag lines) appears exactly once
#   4. Order-preserving: lines appear in the same order they were emitted
#   5. test-gate tee: the { cmd; echo $? > file; } | tee pattern preserves exit codes
#   6. Structural: bin/rite uses FIFO pattern; test-gate.sh tees to stdout

setup() {
  command -v perl >/dev/null || skip "perl not available"
  export BATS_TEST_DIR="${BATS_TEST_TMPDIR}/run-log-test"
  mkdir -p "$BATS_TEST_DIR"
}

teardown() {
  rm -rf "$BATS_TEST_DIR"
}

# ---------------------------------------------------------------------------
# Helper: write a harness script that simulates the bin/rite FIFO-based tee.
# Note: scripts are written using printf to avoid heredoc/brace-matching
# issues when bats functions contain closing braces in embedded scripts.
# ---------------------------------------------------------------------------
_write_tee_harness() {
  local script="$1"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'LOG_FILE="$1"' \
    'strip_ansi() { perl -pe '"'"'BEGIN { $| = 1 } s/\e\[[0-9;]*[a-zA-Z]//g'"'"'; }' \
    '_fifo=$(mktemp -u "${TMPDIR:-/tmp}/rite_log_XXXXXX")' \
    'mkfifo "$_fifo"' \
    '( strip_ansi < "$_fifo" >> "$LOG_FILE"; rm -f "$_fifo" ) &' \
    '_bg_pid=$!' \
    'trap '"'"'exec 1>&-; wait "$_bg_pid"'"'"' EXIT' \
    'exec > >(tee "$_fifo")' \
    'exec 2>&1' \
    'echo -e "\033[0;32mphase: dev-start\033[0m"' \
    'bash -c '"'"'echo "subprocess-line-alpha"; echo "subprocess-line-beta"'"'"'' \
    'printf '"'"'\033[0;33m⚡ Read\033[0m\n'"'"'' \
    'echo "[diag] 12:00:00 | WORKFLOW_COMPLETE issue=42" >> "$LOG_FILE"' \
    'echo "parent-final-line"' \
    > "$script"
  chmod +x "$script"
}

# ---------------------------------------------------------------------------
# 1. Full-transcript test: subprocess stdout appears in the log file
# ---------------------------------------------------------------------------
@test "full-transcript: subprocess stdout captured in log file" {
  local _script="$BATS_TEST_DIR/tee-harness.sh"
  local _log="$BATS_TEST_DIR/test-run.log"
  touch "$_log"
  _write_tee_harness "$_script"

  run bash "$_script" "$_log"
  [ "$status" -eq 0 ]

  grep -q "subprocess-line-alpha" "$_log"
  grep -q "subprocess-line-beta" "$_log"
  grep -q "phase: dev-start" "$_log"
  grep -q "parent-final-line" "$_log"
}

# ---------------------------------------------------------------------------
# 2. ANSI-stripped test: log file contains no escape sequences
# ---------------------------------------------------------------------------
@test "ansi-stripped: log file contains no ANSI escape sequences" {
  local _script="$BATS_TEST_DIR/tee-harness.sh"
  local _log="$BATS_TEST_DIR/test-run.log"
  touch "$_log"
  _write_tee_harness "$_script"

  run bash "$_script" "$_log"
  [ "$status" -eq 0 ]

  # grep -q $'\033' checks for literal ESC byte — no ANSI in the log
  if grep -q $'\033' "$_log" 2>/dev/null; then
    echo "FAIL: log file contains ANSI escape sequences" >&2
    cat "$_log" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. No-double-diag test: _diag direct-write lines appear exactly once
# ---------------------------------------------------------------------------
@test "no-double-diag: WORKFLOW_COMPLETE appears exactly once in log" {
  local _script="$BATS_TEST_DIR/tee-harness.sh"
  local _log="$BATS_TEST_DIR/test-run.log"
  touch "$_log"
  _write_tee_harness "$_script"

  run bash "$_script" "$_log"
  [ "$status" -eq 0 ]

  local _count
  _count=$(grep -c "WORKFLOW_COMPLETE" "$_log" || true)
  if [ "$_count" -ne 1 ]; then
    echo "FAIL: WORKFLOW_COMPLETE found $_count times (expected exactly 1)" >&2
    cat "$_log" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 4. Order-preserving test: lines appear in emission order
# ---------------------------------------------------------------------------
@test "order-preserving: log lines appear in emission order" {
  local _script="$BATS_TEST_DIR/order-test.sh"
  local _log="$BATS_TEST_DIR/order-test.log"
  touch "$_log"

  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'LOG_FILE="$1"' \
    'strip_ansi() { perl -pe '"'"'BEGIN { $| = 1 } s/\e\[[0-9;]*[a-zA-Z]//g'"'"'; }' \
    '_fifo=$(mktemp -u "${TMPDIR:-/tmp}/rite_log_XXXXXX")' \
    'mkfifo "$_fifo"' \
    '( strip_ansi < "$_fifo" >> "$LOG_FILE"; rm -f "$_fifo" ) &' \
    '_bg_pid=$!' \
    'trap '"'"'exec 1>&-; wait "$_bg_pid"'"'"' EXIT' \
    'exec > >(tee "$_fifo")' \
    'exec 2>&1' \
    'echo "line-A"' \
    'bash -c '"'"'echo "line-B"'"'"'' \
    'echo "line-C"' \
    > "$_script"
  chmod +x "$_script"

  run bash "$_script" "$_log"
  [ "$status" -eq 0 ]

  grep -q "line-A" "$_log"
  grep -q "line-B" "$_log"
  grep -q "line-C" "$_log"

  # A must appear before C in the log
  local _line_a _line_c
  _line_a=$(grep -n "line-A" "$_log" | cut -d: -f1 | head -1 || true)
  _line_c=$(grep -n "line-C" "$_log" | cut -d: -f1 | head -1 || true)
  if [ -n "$_line_a" ] && [ -n "$_line_c" ]; then
    if [ "$_line_a" -gt "$_line_c" ]; then
      echo "FAIL: line-A (log line $_line_a) appeared after line-C (log line $_line_c)" >&2
      cat "$_log" >&2
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# 5. test-gate tee: the { cmd; echo $? > file; } | tee pattern works correctly
#    — exit code of the inner command is preserved, output flows to temp file
# ---------------------------------------------------------------------------
@test "test-gate tee pattern: exit code captured and output flows to temp file" {
  local _exit_file="$BATS_TEST_DIR/exit_capture.txt"
  local _raw_file="$BATS_TEST_DIR/raw_output.txt"

  # Simulate passing command
  { (echo "gate-output-line-1"; echo "gate-output-line-2"; exit 0); echo $? > "$_exit_file"; } \
    | tee "$_raw_file" > /dev/null || true
  local _exit
  _exit=$(cat "$_exit_file" 2>/dev/null || echo "1")

  [ "$_exit" -eq 0 ]
  grep -q "gate-output-line-1" "$_raw_file"
  grep -q "gate-output-line-2" "$_raw_file"

  rm -f "$_exit_file" "$_raw_file"

  # Simulate failing command (exit 1)
  { (echo "gate-fail-output"; exit 1); echo $? > "$_exit_file"; } \
    | tee "$_raw_file" > /dev/null || true
  _exit=$(cat "$_exit_file" 2>/dev/null || echo "0")

  [ "$_exit" -eq 1 ]
  grep -q "gate-fail-output" "$_raw_file"
}

# ---------------------------------------------------------------------------
# 6. Structural: bin/rite uses FIFO tee pattern (not nested process substitution)
# ---------------------------------------------------------------------------
@test "structural: bin/rite uses FIFO-based tee not nested process substitution" {
  local _project_root
  _project_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  grep -q "mkfifo" "$_project_root/bin/rite"
  grep -q "_rite_log_fifo" "$_project_root/bin/rite"

  if grep -vE '^\s*#' "$_project_root/bin/rite" | grep -q 'tee >(strip_ansi'; then
    echo "FAIL: bin/rite still uses old nested process-substitution tee pattern" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 7. Structural: test-gate.sh tees output to stdout for make and bats runners
# ---------------------------------------------------------------------------
@test "structural: test-gate.sh tees subprocess output to stdout" {
  local _project_root
  _project_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  grep -q 'tee -a.*_lint_raw_file' "$_project_root/lib/utils/test-gate.sh"
  grep -q 'tee.*_tests_raw_file' "$_project_root/lib/utils/test-gate.sh"
}
