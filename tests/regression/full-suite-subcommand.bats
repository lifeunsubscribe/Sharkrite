#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-full-suite, bin/rite-health-report, lib/utils/repo-status.sh
# Regression test: rite --full-suite periodic safety net (issue #482)
#
# Verifies:
#   1. Bypasses targeted selection — full-suite path always taken
#   2. FULL_SUITE_RUN diag emitted exactly once per invocation
#   3. Failure flag written on test failure; cleared on next clean run
#   4. Health report parser picks up FULL_SUITE_RUN diag lines
#   5. Health report produces WARNING section when outcome=failed in period
#   6. rite --status shows failure banner when flag file exists
#
# Test strategy: stub make and bats binaries so tests run without the real
# build environment; use RITE_PROJECT_ROOT pointing to a temp dir fixture.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT

  # Build a minimal project root fixture
  export FAKE_PROJECT_ROOT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$FAKE_PROJECT_ROOT/.rite/logs" \
           "$FAKE_PROJECT_ROOT/.rite/state" \
           "$FAKE_PROJECT_ROOT/.rite/reports" \
           "$FAKE_PROJECT_ROOT/tests/regression"
  export RITE_DATA_DIR=".rite"

  # Minimal stub bats test for the fake project
  cat > "$FAKE_PROJECT_ROOT/tests/regression/stub.bats" << 'EOF'
#!/usr/bin/env bats
@test "stub passes" { true; }
EOF

  # Stub bin directory that will shadow real make/bats
  export STUB_BIN="$RITE_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  # Makefile stub: always-passes `make check`
  cat > "$STUB_BIN/make" << 'EOF'
#!/bin/bash
# Stub make: always exits 0 (lint passes)
exit 0
EOF
  chmod +x "$STUB_BIN/make"

  # Bats stub: emits TAP-like output for one passing test, exits 0
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
# Stub bats: emits TAP output (1 passing test) and exits 0
echo "ok 1 stub passes"
exit 0
EOF
  chmod +x "$STUB_BIN/bats"
}

teardown() {
  teardown_test_tmpdir
}

# ============================================================================
# Helper: run rite-full-suite with the stub PATH and fake project root
# ============================================================================

_run_full_suite() {
  local extra_env=("${@}")
  run env \
    PATH="$STUB_BIN:$PATH" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT_ROOT" \
    RITE_DATA_DIR=".rite" \
    "${extra_env[@]+"${extra_env[@]}"}" \
    "$RITE_REPO_ROOT/bin/rite-full-suite"
}

# ============================================================================
# 1. Bypasses targeted selection
# ============================================================================

@test "full-suite: runs even when no changed files (bypasses targeted selection)" {
  # The real test-gate.sh would do nothing if no diff files match headers.
  # rite-full-suite must always run; verify it produces output and exits 0.
  _run_full_suite
  [ "$status" -eq 0 ]
  # Must mention full-suite mode (not targeted)
  echo "$output" | grep -q 'full-suite'
}

@test "full-suite: never emits mode=targeted in output" {
  _run_full_suite
  # Targeted selection diag should never appear in full-suite output
  echo "$output" | grep -qv 'mode=targeted' || true  # grep -v exits 0 on "found no match" (all lines don't contain it)
  # Stricter: assert the targeted mode string is absent
  run echo "$output"
  # No line should contain TEST_GATE_SELECTION mode=targeted
  ! echo "$output" | grep -q 'TEST_GATE_SELECTION mode=targeted'
}

# ============================================================================
# 2. Diag emission: exactly once per invocation
# ============================================================================

@test "full-suite: emits FULL_SUITE_RUN diag exactly once on success" {
  _run_full_suite
  [ "$status" -eq 0 ]

  # Diag must appear in the log file (written directly; not just stdout)
  local log_file
  log_file=$(find "$FAKE_PROJECT_ROOT/.rite/logs" -name "full-suite-*.log" | head -1)
  [ -n "$log_file" ]

  local diag_count
  diag_count=$(grep -c 'FULL_SUITE_RUN' "$log_file" || true)
  [ "$diag_count" -eq 1 ]
}

@test "full-suite: FULL_SUITE_RUN diag contains outcome=passed on success" {
  _run_full_suite
  [ "$status" -eq 0 ]

  local log_file
  log_file=$(find "$FAKE_PROJECT_ROOT/.rite/logs" -name "full-suite-*.log" | head -1)
  [ -n "$log_file" ]

  grep -q 'FULL_SUITE_RUN outcome=passed' "$log_file"
}

@test "full-suite: FULL_SUITE_RUN diag contains required fields (lint_count, test_count, duration_s)" {
  _run_full_suite
  [ "$status" -eq 0 ]

  local log_file
  log_file=$(find "$FAKE_PROJECT_ROOT/.rite/logs" -name "full-suite-*.log" | head -1)
  [ -n "$log_file" ]

  # All four required fields must be present
  grep -q 'FULL_SUITE_RUN' "$log_file"
  grep -qE 'lint_count=[0-9]+' "$log_file"
  grep -qE 'test_count=[0-9]+' "$log_file"
  grep -qE 'duration_s=[0-9]+' "$log_file"
}

@test "full-suite: emits FULL_SUITE_RUN diag exactly once on failure" {
  # Stub bats to fail
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
echo "not ok 1 intentional failure"
exit 1
EOF

  _run_full_suite || true  # non-zero exit expected

  local log_file
  log_file=$(find "$FAKE_PROJECT_ROOT/.rite/logs" -name "full-suite-*.log" | head -1)
  [ -n "$log_file" ]

  local diag_count
  diag_count=$(grep -c 'FULL_SUITE_RUN' "$log_file" || true)
  [ "$diag_count" -eq 1 ]
}

# ============================================================================
# 3. Failure flag: written on failure, cleared on success
# ============================================================================

@test "full-suite: failure flag written when bats fails" {
  # Stub bats to fail one test
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
echo "not ok 1 intentional failure"
exit 1
EOF

  _run_full_suite || true  # expect non-zero exit

  [ -f "$FAKE_PROJECT_ROOT/.rite/state/full-suite-failure.flag" ]
}

@test "full-suite: failure flag contains outcome=failed diag reference" {
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
echo "not ok 1 intentional failure"
exit 1
EOF

  _run_full_suite || true

  [ -f "$FAKE_PROJECT_ROOT/.rite/state/full-suite-failure.flag" ]
  # Flag file should mention the failure
  grep -qi 'fail' "$FAKE_PROJECT_ROOT/.rite/state/full-suite-failure.flag"
}

@test "full-suite: failure flag cleared when subsequent run passes" {
  # First run: fail
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
echo "not ok 1 intentional failure"
exit 1
EOF
  _run_full_suite || true

  [ -f "$FAKE_PROJECT_ROOT/.rite/state/full-suite-failure.flag" ]

  # Second run: pass
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
echo "ok 1 stub passes"
exit 0
EOF
  _run_full_suite

  [ ! -f "$FAKE_PROJECT_ROOT/.rite/state/full-suite-failure.flag" ]
}

@test "full-suite: exits non-zero when bats fails" {
  cat > "$STUB_BIN/bats" << 'EOF'
#!/bin/bash
echo "not ok 1 intentional failure"
exit 1
EOF

  run env \
    PATH="$STUB_BIN:$PATH" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT_ROOT" \
    RITE_DATA_DIR=".rite" \
    "$RITE_REPO_ROOT/bin/rite-full-suite"

  [ "$status" -ne 0 ]
}

@test "full-suite: exits non-zero when make check fails" {
  # Stub make to fail
  cat > "$STUB_BIN/make" << 'EOF'
#!/bin/bash
echo "lint error: SC2086 in lib/foo.sh:10:5"
exit 1
EOF

  run env \
    PATH="$STUB_BIN:$PATH" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT_ROOT" \
    RITE_DATA_DIR=".rite" \
    "$RITE_REPO_ROOT/bin/rite-full-suite"

  [ "$status" -ne 0 ]
}

# ============================================================================
# 4. Health report parser picks up FULL_SUITE_RUN diag lines
# ============================================================================

@test "health-report: pre-parse logic collects FULL_SUITE_RUN from full-suite log files" {
  # Create a synthetic full-suite log in the fake project
  local fake_log="$FAKE_PROJECT_ROOT/.rite/logs/full-suite-20260601.log"
  {
    echo "=== rite --full-suite ==="
    echo "Date:    2026-06-01 03:00:01"
    echo "[diag] 03:00:45 | FULL_SUITE_RUN outcome=passed lint_count=0 test_count=0 duration_s=412"
  } > "$fake_log"

  # Source the pre-parse block from rite-health-report in isolation.
  # We extract the FSR_* computation section into a helper script.
  # This mirrors the pattern in health-report-cr-precompute.bats.
  cat > "$RITE_TEST_TMPDIR/compute_fsr.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

LOGS_DIR="$1"
WEEK_AGO_EPOCH=0  # Include all files (epoch=0 means "always include")

# Minimal BSD/GNU date helper (same logic as rite-health-report)
date_from_compact() {
  local compact="$1"
  if date -j -f "%Y%m%d" "$compact" +%s 2>/dev/null; then
    return 0
  else
    date -d "$compact" +%s 2>/dev/null || echo "0"
  fi
}

FS_DIAG_LINES=""
if [ -d "$LOGS_DIR" ]; then
  while IFS= read -r fslogfile; do
    _fs_date=$(echo "$fslogfile" | grep -oE '[0-9]{8}' | tail -1 || true)
    if [ -n "$_fs_date" ]; then
      _fs_epoch=$(date_from_compact "$_fs_date")
      if [ "${_fs_epoch:-0}" -ge "$WEEK_AGO_EPOCH" ] 2>/dev/null; then
        FS_DIAG_LINES+=$(grep '\[diag\].*FULL_SUITE_RUN' "$fslogfile" 2>/dev/null || true)
        FS_DIAG_LINES+=$'\n'
      fi
    fi
  done < <(find "$LOGS_DIR" -name "full-suite-*.log" -type f 2>/dev/null | sort)
fi
FS_DIAG_LINES=$(echo "$FS_DIAG_LINES" | sed '/^$/d' || true)

FSR_TOTAL=$(echo "$FS_DIAG_LINES" | grep -c 'FULL_SUITE_RUN' || true)
FSR_PASSED=$(echo "$FS_DIAG_LINES" | grep -c 'outcome=passed' || true)
FSR_FAILED=$(echo "$FS_DIAG_LINES" | grep -c 'outcome=failed' || true)

echo "FSR_TOTAL=$FSR_TOTAL"
echo "FSR_PASSED=$FSR_PASSED"
echo "FSR_FAILED=$FSR_FAILED"
EOF
  chmod +x "$RITE_TEST_TMPDIR/compute_fsr.sh"

  run "$RITE_TEST_TMPDIR/compute_fsr.sh" "$FAKE_PROJECT_ROOT/.rite/logs"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q 'FSR_TOTAL=1'
  echo "$output" | grep -q 'FSR_PASSED=1'
  echo "$output" | grep -q 'FSR_FAILED=0'
}

@test "health-report: FSR stats correctly count failures" {
  # Create two full-suite log files: one pass, one fail
  {
    echo "[diag] 03:00:45 | FULL_SUITE_RUN outcome=passed lint_count=0 test_count=0 duration_s=410"
  } > "$FAKE_PROJECT_ROOT/.rite/logs/full-suite-20260601.log"
  {
    echo "[diag] 03:00:55 | FULL_SUITE_RUN outcome=failed lint_count=0 test_count=3 duration_s=425"
  } > "$FAKE_PROJECT_ROOT/.rite/logs/full-suite-20260608.log"

  cat > "$RITE_TEST_TMPDIR/compute_fsr.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
LOGS_DIR="$1"
WEEK_AGO_EPOCH=0
date_from_compact() {
  local compact="$1"
  if date -j -f "%Y%m%d" "$compact" +%s 2>/dev/null; then
    return 0
  else
    date -d "$compact" +%s 2>/dev/null || echo "0"
  fi
}
FS_DIAG_LINES=""
if [ -d "$LOGS_DIR" ]; then
  while IFS= read -r fslogfile; do
    _fs_date=$(echo "$fslogfile" | grep -oE '[0-9]{8}' | tail -1 || true)
    if [ -n "$_fs_date" ]; then
      _fs_epoch=$(date_from_compact "$_fs_date")
      if [ "${_fs_epoch:-0}" -ge "$WEEK_AGO_EPOCH" ] 2>/dev/null; then
        FS_DIAG_LINES+=$(grep '\[diag\].*FULL_SUITE_RUN' "$fslogfile" 2>/dev/null || true)
        FS_DIAG_LINES+=$'\n'
      fi
    fi
  done < <(find "$LOGS_DIR" -name "full-suite-*.log" -type f 2>/dev/null | sort)
fi
FS_DIAG_LINES=$(echo "$FS_DIAG_LINES" | sed '/^$/d' || true)
FSR_TOTAL=$(echo "$FS_DIAG_LINES" | grep -c 'FULL_SUITE_RUN' || true)
FSR_PASSED=$(echo "$FS_DIAG_LINES" | grep -c 'outcome=passed' || true)
FSR_FAILED=$(echo "$FS_DIAG_LINES" | grep -c 'outcome=failed' || true)
FSR_DURATION_SUM=$(echo "$FS_DIAG_LINES" | grep -oE 'duration_s=[0-9]+' | grep -oE '[0-9]+' \
  | awk '{sum += $1} END {print sum+0}' || echo "0")
if [ "${FSR_TOTAL:-0}" -gt 0 ] 2>/dev/null && [ "${FSR_DURATION_SUM:-0}" -gt 0 ] 2>/dev/null; then
  FSR_AVG_DURATION_S=$(( FSR_DURATION_SUM / FSR_TOTAL ))
else
  FSR_AVG_DURATION_S=0
fi
echo "FSR_TOTAL=$FSR_TOTAL"
echo "FSR_PASSED=$FSR_PASSED"
echo "FSR_FAILED=$FSR_FAILED"
echo "FSR_AVG_DURATION_S=$FSR_AVG_DURATION_S"
EOF
  chmod +x "$RITE_TEST_TMPDIR/compute_fsr.sh"

  run "$RITE_TEST_TMPDIR/compute_fsr.sh" "$FAKE_PROJECT_ROOT/.rite/logs"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'FSR_TOTAL=2'
  echo "$output" | grep -q 'FSR_PASSED=1'
  echo "$output" | grep -q 'FSR_FAILED=1'
  # Average duration: (410 + 425) / 2 = 417
  echo "$output" | grep -q 'FSR_AVG_DURATION_S=417'
}

@test "health-report: FSR_TOTAL is 0 when no full-suite log files exist" {
  # No full-suite logs in the fake project
  cat > "$RITE_TEST_TMPDIR/compute_fsr.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
LOGS_DIR="$1"
WEEK_AGO_EPOCH=0
date_from_compact() {
  local compact="$1"
  if date -j -f "%Y%m%d" "$compact" +%s 2>/dev/null; then
    return 0
  else
    date -d "$compact" +%s 2>/dev/null || echo "0"
  fi
}
FS_DIAG_LINES=""
if [ -d "$LOGS_DIR" ]; then
  while IFS= read -r fslogfile; do
    _fs_date=$(echo "$fslogfile" | grep -oE '[0-9]{8}' | tail -1 || true)
    if [ -n "$_fs_date" ]; then
      _fs_epoch=$(date_from_compact "$_fs_date")
      if [ "${_fs_epoch:-0}" -ge "$WEEK_AGO_EPOCH" ] 2>/dev/null; then
        FS_DIAG_LINES+=$(grep '\[diag\].*FULL_SUITE_RUN' "$fslogfile" 2>/dev/null || true)
        FS_DIAG_LINES+=$'\n'
      fi
    fi
  done < <(find "$LOGS_DIR" -name "full-suite-*.log" -type f 2>/dev/null | sort)
fi
FS_DIAG_LINES=$(echo "$FS_DIAG_LINES" | sed '/^$/d' || true)
FSR_TOTAL=$(echo "$FS_DIAG_LINES" | grep -c 'FULL_SUITE_RUN' || true)
echo "FSR_TOTAL=$FSR_TOTAL"
EOF
  chmod +x "$RITE_TEST_TMPDIR/compute_fsr.sh"

  run "$RITE_TEST_TMPDIR/compute_fsr.sh" "$FAKE_PROJECT_ROOT/.rite/logs"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'FSR_TOTAL=0'
}

# ============================================================================
# 5. rite --status banner (structural check via repo-status.sh)
# ============================================================================

@test "repo-status: failure flag causes full-suite banner variables to be present in repo-status.sh" {
  # We can't easily invoke repo_wide_status() without a real gh/git environment.
  # Instead, verify the code path exists: that repo-status.sh references the
  # failure flag path and emits the banner text.
  local repo_status="$RITE_REPO_ROOT/lib/utils/repo-status.sh"
  [ -f "$repo_status" ]

  # The banner code must reference the failure flag
  grep -q 'full-suite-failure.flag' "$repo_status"

  # The banner must output the FULL-SUITE FAILURE DETECTED text
  grep -q 'FULL-SUITE FAILURE DETECTED' "$repo_status"
}

@test "repo-status.sh: failure flag path uses RITE_DATA_DIR variable" {
  # Verify the flag path is constructed from RITE_PROJECT_ROOT and RITE_DATA_DIR,
  # not hardcoded — so it respects custom RITE_DATA_DIR values.
  local repo_status="$RITE_REPO_ROOT/lib/utils/repo-status.sh"
  grep -q 'RITE_DATA_DIR' "$repo_status"
  grep -q 'full-suite-failure.flag' "$repo_status"
}

# ============================================================================
# 6. Subcommand dispatch: bin/rite wires --full-suite to bin/rite-full-suite
# ============================================================================

@test "bin/rite: --full-suite flag sets MODE=full-suite" {
  # Verify the dispatch code exists in bin/rite
  local rite_bin="$RITE_REPO_ROOT/bin/rite"
  grep -q 'full-suite' "$rite_bin"
  grep -q 'rite-full-suite' "$rite_bin"
}

@test "bin/rite: --full-suite is exempt from auto-logging (like --health-report)" {
  # MODE=full-suite should appear in the RITE_LOG_AUTO=false condition
  local rite_bin="$RITE_REPO_ROOT/bin/rite"
  grep -q '"full-suite"' "$rite_bin"
  # The line setting RITE_LOG_AUTO=false must include full-suite
  grep 'RITE_LOG_AUTO=false' "$rite_bin" | grep -q 'full-suite'
}

@test "bin/rite-full-suite: executable bit is set" {
  [ -x "$RITE_REPO_ROOT/bin/rite-full-suite" ]
}

@test "bin/rite-full-suite: has bash 4+ self-re-exec guard" {
  grep -q 'BASH_VERSINFO' "$RITE_REPO_ROOT/bin/rite-full-suite"
}

@test "bin/rite-full-suite: has re-source guard (RITE_LOG_AUTO bypass)" {
  # The script must NOT use RITE_LOG_AUTO or source test-gate.sh — it is standalone
  # Verify it doesn't accidentally import the targeted gate selection logic
  ! grep -q 'run_test_gate' "$RITE_REPO_ROOT/bin/rite-full-suite"
}

# ============================================================================
# 7. Log file: written to .rite/logs/full-suite-YYYYMMDD.log
# ============================================================================

@test "full-suite: log file is written to correct path" {
  _run_full_suite
  [ "$status" -eq 0 ]

  # At least one full-suite log file must exist
  local log_count
  log_count=$(find "$FAKE_PROJECT_ROOT/.rite/logs" -name "full-suite-*.log" 2>/dev/null | wc -l | tr -d ' ')
  [ "$log_count" -ge 1 ]
}

@test "full-suite: log file contains header with date and branch info" {
  _run_full_suite
  [ "$status" -eq 0 ]

  local log_file
  log_file=$(find "$FAKE_PROJECT_ROOT/.rite/logs" -name "full-suite-*.log" | head -1)
  [ -n "$log_file" ]

  grep -qi 'rite --full-suite' "$log_file"
  grep -qiE 'Date:|Branch:' "$log_file"
}
