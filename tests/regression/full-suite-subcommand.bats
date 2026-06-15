#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-full-suite, bin/rite
# tests/regression/full-suite-subcommand.bats
#
# Regression tests for the periodic full-suite safety net (#482).
#
# Tests verify:
#  1. Bypasses targeted selection: rite --full-suite always runs bats -r tests/
#     even when changed-files would have selected a subset.
#  2. Diag emission: [diag] FULL_SUITE_RUN appears exactly once per invocation.
#  3. Failure flag: written on bats failure, deleted on next successful run.
#  4. Health report parser picks up FULL_SUITE_RUN events from full-suite-*.log.
#
# Pattern mirrors health-report-cr-precompute.bats: helper scripts written to
# BATS_TEST_TMPDIR exercise the exact bash logic from the production scripts.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Fake project structure used by all tests
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite/logs" "$_FAKE_PROJECT/.rite/state" "$_FAKE_PROJECT/.rite/reports"

  # The bin/rite-full-suite script under test
  export _FULL_SUITE_SCRIPT="$RITE_REPO_ROOT/bin/rite-full-suite"

  # Fake Makefile that records the call and exits 0
  cat > "$_FAKE_PROJECT/Makefile" << 'EOF'
.PHONY: check shellcheck lint
check:
	@echo "make check called" >> "$$(pwd)/.rite/state/make-check-calls"
	@exit 0
shellcheck:
	@exit 0
lint:
	@exit 0
EOF
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a minimal stub bin/ into FAKE_PROJECT so rite-full-suite can
# find its own siblings (colors.sh, config.sh, etc.) without a real install.
# ---------------------------------------------------------------------------
_write_lib_stubs() {
  mkdir -p "$_FAKE_PROJECT/lib/utils"

  # Minimal config.sh stub
  cat > "$_FAKE_PROJECT/lib/utils/config.sh" << 'STUB'
#!/bin/bash
# stub: config.sh
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT:-$(pwd)}"
RITE_LIB_DIR="${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/.."}"
RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-fake-project}"
export RITE_DATA_DIR RITE_PROJECT_ROOT RITE_LIB_DIR RITE_PROJECT_NAME
STUB

  # Minimal colors.sh stub (print_* and strip_ansi)
  cat > "$_FAKE_PROJECT/lib/utils/colors.sh" << 'STUB'
#!/bin/bash
# stub: colors.sh
print_header()  { echo "=== $* ==="; }
print_info()    { echo "[INFO] $*"; }
print_step()    { echo "[STEP] $*"; }
print_success() { echo "[OK] $*"; }
print_warning() { echo "[WARN] $*"; }
print_error()   { echo "[ERROR] $*" >&2; }
strip_ansi()    { cat; }
STUB

  # Minimal logging.sh stub (provides _diag)
  cat > "$_FAKE_PROJECT/lib/utils/logging.sh" << 'STUB'
#!/bin/bash
# stub: logging.sh
_RITE_LOGGING_LOADED=true
is_verbose() { [ "${RITE_VERBOSE:-false}" = "true" ]; }
_diag() {
  local msg="$1"
  local ts; ts=$(date '+%H:%M:%S')
  local line="[diag] $ts | $msg"
  if [ -n "${RITE_LOG_FILE:-}" ]; then
    echo "$line" >> "$RITE_LOG_FILE"
  else
    echo "$line" >&2
  fi
}
verbose_header()  { true; }
verbose_info()    { true; }
verbose_step()    { true; }
verbose_success() { true; }
verbose_warning() { true; }
STUB
}

# ---------------------------------------------------------------------------
# Test 1: Bypasses selection — full-suite path, not targeted
#
# Strategy: stub bats to record which arguments it was called with;
# verify that bats was called with "-r tests/" (full sweep), not with a
# targeted file list that targeted selection would produce.
# ---------------------------------------------------------------------------
@test "full-suite: invokes bats -r tests/ (bypasses targeted selection)" {
  _write_lib_stubs

  # Stub bats: records arguments and exits 0
  mkdir -p "$_FAKE_PROJECT/bin"
  cat > "$_FAKE_PROJECT/bin/bats" << 'EOF'
#!/bin/bash
echo "bats-called: $*" >> "$BATS_CALL_LOG"
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  # Stub make: records call and exits 0
  cat > "$_FAKE_PROJECT/bin/make" << 'EOF'
#!/bin/bash
echo "make-called: $*" >> "$BATS_CALL_LOG"
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/make"

  export BATS_CALL_LOG="$RITE_TEST_TMPDIR/bats-calls.log"
  mkdir -p "$_FAKE_PROJECT/tests"

  # Invoke the script with our stub PATH and fake project root
  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    BATS_CALL_LOG="$BATS_CALL_LOG" \
    bash "$_FULL_SUITE_SCRIPT"

  # bats must have been called with -r tests/ (full sweep)
  [ -f "$BATS_CALL_LOG" ]
  grep -q "\-r tests/" "$BATS_CALL_LOG"
  # It must NOT have been called with a targeted subset (comma-separated file list)
  ! grep -q "\-r tests/regression/.*\.bats" "$BATS_CALL_LOG"
}

# ---------------------------------------------------------------------------
# Test 2: Diag emission — exactly one FULL_SUITE_RUN per invocation
# ---------------------------------------------------------------------------
@test "full-suite: emits [diag] FULL_SUITE_RUN exactly once" {
  _write_lib_stubs

  mkdir -p "$_FAKE_PROJECT/bin" "$_FAKE_PROJECT/tests"

  # Stub bats and make to succeed silently
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/bats"
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/make"
  chmod +x "$_FAKE_PROJECT/bin/bats" "$_FAKE_PROJECT/bin/make"

  local _log_file="$_FAKE_PROJECT/.rite/logs/full-suite-test.log"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT"

  # Find the log file written by the run (full-suite-*.log)
  local _written_log
  _written_log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_written_log" ]

  # Exactly one FULL_SUITE_RUN diag line
  local _count
  _count=$(grep -c 'FULL_SUITE_RUN' "$_written_log" || true)
  [ "$_count" -eq 1 ]

  # Must carry outcome= field
  grep -q 'outcome=' "$_written_log"
  # Must carry lint_count= and test_count= and duration_s=
  grep -q 'lint_count=' "$_written_log"
  grep -q 'test_count=' "$_written_log"
  grep -q 'duration_s=' "$_written_log"
}

# ---------------------------------------------------------------------------
# Test 3a: Failure flag written when bats fails
# ---------------------------------------------------------------------------
@test "full-suite: writes failure flag when tests fail" {
  _write_lib_stubs

  mkdir -p "$_FAKE_PROJECT/bin" "$_FAKE_PROJECT/tests"

  # make check succeeds
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/make"
  chmod +x "$_FAKE_PROJECT/bin/make"

  # bats fails and emits a "not ok" line
  cat > "$_FAKE_PROJECT/bin/bats" << 'EOF'
#!/bin/bash
echo "not ok 1 intentional-fail-for-test"
exit 1
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT"

  # Failure flag must exist
  [ -f "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag" ]
  # Must contain outcome=failed
  grep -q 'outcome=failed' "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag"
  # Must list the failing test
  grep -q 'intentional-fail-for-test' "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag"
}

# ---------------------------------------------------------------------------
# Test 3b: Failure flag deleted on next successful run
# ---------------------------------------------------------------------------
@test "full-suite: deletes failure flag on successful run" {
  _write_lib_stubs

  mkdir -p "$_FAKE_PROJECT/bin" "$_FAKE_PROJECT/tests"

  # Pre-plant a failure flag
  echo "outcome=failed" > "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag"

  # Now both make and bats succeed
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/make"
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/bats"
  chmod +x "$_FAKE_PROJECT/bin/make" "$_FAKE_PROJECT/bin/bats"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT"

  [ "$status" -eq 0 ]
  # Failure flag must be gone
  [ ! -f "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag" ]
}

# ---------------------------------------------------------------------------
# Test 4: Health report parser picks up FULL_SUITE_RUN events
#
# Strategy: write a synthetic full-suite-*.log file containing FULL_SUITE_RUN
# diag lines, then exercise the pre-parsing logic from bin/rite-health-report
# via an extracted helper script. Verify FSR_TOTAL, FSR_PASSED, FSR_FAILED,
# and the failure flag detection.
# ---------------------------------------------------------------------------
@test "health-report: FSR parser counts FULL_SUITE_RUN events correctly" {
  # Write a helper that replicates the pre-parse block from bin/rite-health-report.
  # Reads FSR_LOGS_DIR and FSR_FLAG from env; prints FSR_TOTAL FSR_PASSED FSR_FAILED.
  cat > "$RITE_TEST_TMPDIR/compute_fsr.sh" << 'HELPEREOF'
#!/bin/bash
set -euo pipefail

LOGS_DIR="${FSR_LOGS_DIR:-}"
WEEK_AGO_EPOCH="${FSR_WEEK_AGO:-0}"

# Mirrors the health-report pre-parse block for FULL_SUITE_RUN
FSR_DIAG_LINES=""
if [ -d "$LOGS_DIR" ]; then
  while IFS= read -r logfile; do
    _log_date=$(echo "$logfile" | grep -oE '[0-9]{8}' | tail -1 || true)
    if [ -n "$_log_date" ]; then
      # Accept all log files in test (override epoch check by using epoch 0)
      FSR_DIAG_LINES+=$(grep '\[diag\].*FULL_SUITE_RUN ' "$logfile" 2>/dev/null || true)
      FSR_DIAG_LINES+=$'\n'
    fi
  done < <(find "$LOGS_DIR" -name "*.log" -type f 2>/dev/null | sort)
fi
FSR_DIAG_LINES=$(echo "$FSR_DIAG_LINES" | sed '/^$/d' || true)

FSR_TOTAL=$(echo "$FSR_DIAG_LINES" | grep -c 'FULL_SUITE_RUN ' || true)
FSR_PASSED=$(echo "$FSR_DIAG_LINES" | grep -c 'outcome=passed' || true)
FSR_FAILED=$(echo "$FSR_DIAG_LINES" | grep -c 'outcome=failed' || true)
FSR_LINT_TOTAL=$(echo "$FSR_DIAG_LINES" | grep -oE 'lint_count=[0-9]+' | grep -oE '[0-9]+' | awk '{sum += $1} END {print sum+0}' || echo "0")
FSR_TEST_TOTAL=$(echo "$FSR_DIAG_LINES" | grep -oE 'test_count=[0-9]+' | grep -oE '[0-9]+' | awk '{sum += $1} END {print sum+0}' || echo "0")
FSR_AVG_DURATION_S="N/A"
if [ "${FSR_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
  _fsr_dur_sum=$(echo "$FSR_DIAG_LINES" | grep -oE 'duration_s=[0-9]+' | grep -oE '[0-9]+' | awk '{sum += $1} END {print sum+0}' || echo "0")
  FSR_AVG_DURATION_S="$(( _fsr_dur_sum / FSR_TOTAL ))s"
fi

# Failure flag check
FSR_FAILURE_FLAG_EXISTS=false
_fsr_flag="${FSR_FLAG:-/nonexistent}"
if [ -f "$_fsr_flag" ]; then
  FSR_FAILURE_FLAG_EXISTS=true
fi

echo "FSR_TOTAL=$FSR_TOTAL"
echo "FSR_PASSED=$FSR_PASSED"
echo "FSR_FAILED=$FSR_FAILED"
echo "FSR_LINT_TOTAL=$FSR_LINT_TOTAL"
echo "FSR_TEST_TOTAL=$FSR_TEST_TOTAL"
echo "FSR_AVG_DURATION_S=$FSR_AVG_DURATION_S"
echo "FSR_FAILURE_FLAG_EXISTS=$FSR_FAILURE_FLAG_EXISTS"
HELPEREOF
  chmod +x "$RITE_TEST_TMPDIR/compute_fsr.sh"

  # Write synthetic log files
  local _logs_dir="$RITE_TEST_TMPDIR/logs"
  mkdir -p "$_logs_dir"

  # Two successful runs and one failed run
  cat > "$_logs_dir/full-suite-20260614.log" << 'EOF'
=== Sharkrite Full-Suite Run ===
[diag] 02:00:01 | FULL_SUITE_RUN outcome=passed lint_count=0 test_count=0 duration_s=420
EOF

  cat > "$_logs_dir/full-suite-20260607.log" << 'EOF'
=== Sharkrite Full-Suite Run ===
[diag] 02:00:05 | FULL_SUITE_RUN outcome=passed lint_count=0 test_count=0 duration_s=390
EOF

  cat > "$_logs_dir/full-suite-20260601.log" << 'EOF'
=== Sharkrite Full-Suite Run ===
[diag] 02:00:12 | FULL_SUITE_RUN outcome=failed lint_count=2 test_count=3 duration_s=450
not ok 1 tests/regression/some-test.bats - my failing test
EOF

  # No failure flag (most recent run passed)
  run env \
    FSR_LOGS_DIR="$_logs_dir" \
    FSR_FLAG="$RITE_TEST_TMPDIR/full-suite-failure.flag" \
    "$RITE_TEST_TMPDIR/compute_fsr.sh"

  [ "$status" -eq 0 ]

  # Should count all three runs
  echo "$output" | grep -q "^FSR_TOTAL=3$"
  echo "$output" | grep -q "^FSR_PASSED=2$"
  echo "$output" | grep -q "^FSR_FAILED=1$"
  echo "$output" | grep -q "^FSR_LINT_TOTAL=2$"
  echo "$output" | grep -q "^FSR_TEST_TOTAL=3$"
  # Average of 420+390+450=1260 / 3 = 420s
  echo "$output" | grep -q "^FSR_AVG_DURATION_S=420s$"
  # No failure flag file exists
  echo "$output" | grep -q "^FSR_FAILURE_FLAG_EXISTS=false$"
}

@test "health-report: FSR parser detects failure flag" {
  # Write a helper (same as above but we focus only on flag detection)
  cat > "$RITE_TEST_TMPDIR/check_flag.sh" << 'HELPEREOF'
#!/bin/bash
set -euo pipefail
_fsr_flag="${FSR_FLAG:-/nonexistent}"
FSR_FAILURE_FLAG_EXISTS=false
if [ -f "$_fsr_flag" ]; then
  FSR_FAILURE_FLAG_EXISTS=true
fi
echo "FSR_FAILURE_FLAG_EXISTS=$FSR_FAILURE_FLAG_EXISTS"
HELPEREOF
  chmod +x "$RITE_TEST_TMPDIR/check_flag.sh"

  # Pre-plant a failure flag
  echo "outcome=failed" > "$RITE_TEST_TMPDIR/full-suite-failure.flag"

  run env \
    FSR_FLAG="$RITE_TEST_TMPDIR/full-suite-failure.flag" \
    "$RITE_TEST_TMPDIR/check_flag.sh"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FSR_FAILURE_FLAG_EXISTS=true$"
}

@test "health-report: FSR parser handles no log files gracefully" {
  cat > "$RITE_TEST_TMPDIR/compute_fsr_empty.sh" << 'HELPEREOF'
#!/bin/bash
set -euo pipefail
LOGS_DIR="${FSR_LOGS_DIR:-}"
FSR_DIAG_LINES=""
if [ -d "$LOGS_DIR" ]; then
  while IFS= read -r logfile; do
    FSR_DIAG_LINES+=$(grep '\[diag\].*FULL_SUITE_RUN ' "$logfile" 2>/dev/null || true)
    FSR_DIAG_LINES+=$'\n'
  done < <(find "$LOGS_DIR" -name "*.log" -type f 2>/dev/null | sort)
fi
FSR_DIAG_LINES=$(echo "$FSR_DIAG_LINES" | sed '/^$/d' || true)
FSR_TOTAL=$(echo "$FSR_DIAG_LINES" | grep -c 'FULL_SUITE_RUN ' || true)
echo "FSR_TOTAL=$FSR_TOTAL"
HELPEREOF
  chmod +x "$RITE_TEST_TMPDIR/compute_fsr_empty.sh"

  # No logs dir at all
  run env \
    FSR_LOGS_DIR="$RITE_TEST_TMPDIR/nonexistent-logs" \
    "$RITE_TEST_TMPDIR/compute_fsr_empty.sh"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FSR_TOTAL=0$"
}

# ---------------------------------------------------------------------------
# Test: diag format is exactly [diag] ... FULL_SUITE_RUN outcome=X ...
# (ensures health-report grep patterns will match)
# ---------------------------------------------------------------------------
@test "full-suite: diag line matches expected health-report grep pattern" {
  _write_lib_stubs

  mkdir -p "$_FAKE_PROJECT/bin" "$_FAKE_PROJECT/tests"
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/make"
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/bats"
  chmod +x "$_FAKE_PROJECT/bin/make" "$_FAKE_PROJECT/bin/bats"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT"

  local _log
  _log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_log" ]

  # Pattern used by health-report: grep '\[diag\].*FULL_SUITE_RUN '
  grep -qE '\[diag\].*FULL_SUITE_RUN ' "$_log"
  # Pattern for outcome=passed: grep -c 'outcome=passed'
  grep -q 'outcome=passed' "$_log"
}

# ---------------------------------------------------------------------------
# Test: rite --full-suite dispatch in bin/rite reaches rite-full-suite
# ---------------------------------------------------------------------------
@test "bin/rite --full-suite dispatches to rite-full-suite" {
  # Write a stub rite-full-suite next to bin/rite that records it was called
  local _bin_dir="$RITE_REPO_ROOT/bin"
  local _stub="$RITE_TEST_TMPDIR/rite-full-suite-stub"

  cat > "$_stub" << 'EOF'
#!/bin/bash
echo "FULL_SUITE_STUB_CALLED"
exit 0
EOF
  chmod +x "$_stub"

  # Symlink the stub into a fake bin/ alongside a copy of bin/rite
  local _fake_bin="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_fake_bin"
  ln -s "$RITE_REPO_ROOT/bin/rite" "$_fake_bin/rite"
  ln -sf "$_stub" "$_fake_bin/rite-full-suite"

  # RITE_LIB_DIR points to real lib so bin/rite can source config.sh
  run env \
    PATH="$_fake_bin:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    bash "$_fake_bin/rite" --full-suite

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "FULL_SUITE_STUB_CALLED"
}
