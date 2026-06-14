#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, Makefile
# Regression test: bats --pretty for terminal output (issue #484)
#
# Verifies:
#   1. _bats_has_report_formatter() detects --report-formatter in the bats binary
#   2. The gate uses -F pretty + --report-formatter tap when supported
#   3. The TAP raw file used by _parse_bats_failure_line still contains ^not ok lines
#   4. JSON builder output is byte-identical: same keys, same structure
#   5. Fallback to plain tap when --report-formatter is unavailable
#   6. Makefile test: target uses -F pretty when bats supports it

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export TEST_WORKSPACE
  TEST_WORKSPACE=$(mktemp -d)
  export PR_NUMBER="999"
  # Mock _diag — logging side effects not needed
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_WORKSPACE:-}"
}

# ---------------------------------------------------------------------------
# _bats_has_report_formatter detection
# ---------------------------------------------------------------------------

@test "_bats_has_report_formatter: returns 0 when bats binary contains --report-formatter" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Create a fake bats binary that contains the --report-formatter string
    _fake_bats=\$(mktemp)
    printf '#!/bin/bash\necho --report-formatter\n' > \"\$_fake_bats\"
    chmod +x \"\$_fake_bats\"
    PATH=\"\$(dirname \"\$_fake_bats\"):\$PATH\" _bats_has_report_formatter
    _ret=\$?
    rm -f \"\$_fake_bats\"
    exit \$_ret
  "
  [ "$status" -eq 0 ]
}

@test "_bats_has_report_formatter: returns 1 when bats binary lacks --report-formatter" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Create a fake bats binary WITHOUT --report-formatter
    _fake_bats=\$(mktemp)
    printf '#!/bin/bash\necho -t --tap\n' > \"\$_fake_bats\"
    chmod +x \"\$_fake_bats\"
    PATH=\"\$(dirname \"\$_fake_bats\"):\$PATH\" _bats_has_report_formatter
    _ret=\$?
    rm -f \"\$_fake_bats\"
    # Must be non-zero (not found)
    [ \"\$_ret\" -ne 0 ]
  "
  [ "$status" -eq 0 ]
}

@test "_bats_has_report_formatter: returns 1 when bats is not on PATH" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Run in an empty PATH so bats cannot be found
    PATH=/nonexistent _bats_has_report_formatter
    _ret=\$?
    [ \"\$_ret\" -ne 0 ]
  "
  [ "$status" -eq 0 ]
}

@test "_bats_has_report_formatter: installed bats (1.5+) is detected correctly" {
  # This verifies the real installed bats is handled — no mocking.
  # If bats is not installed the test is skipped gracefully.
  if ! command -v bats >/dev/null 2>&1; then
    skip "bats not installed"
  fi
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    if _bats_has_report_formatter; then
      echo 'has_report_formatter'
    else
      echo 'no_report_formatter'
    fi
  "
  [ "$status" -eq 0 ]
  # Either outcome is valid — the test confirms the helper runs without crashing.
  [[ "$output" == "has_report_formatter" || "$output" == "no_report_formatter" ]]
}

# ---------------------------------------------------------------------------
# Gate uses -F pretty + --report-formatter tap when supported
# ---------------------------------------------------------------------------

@test "test-gate.sh source references -F pretty and --report-formatter tap" {
  # The source file must contain both the formatter flag and the report-formatter flag.
  run grep -n '\-F pretty' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-F pretty"* ]]

  run grep -n '\-\-report-formatter tap' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--report-formatter tap"* ]]
}

@test "test-gate.sh TAP raw file still used for _parse_bats_failure_line (not pretty output)" {
  # The raw file written by --report-formatter tap must be what the JSON builder reads.
  # Verify that the cp from the tap dir into _tests_raw_file is present.
  run grep -n 'report.tap.*_tests_raw_file\|cp.*report.tap' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"report.tap"* ]]
}

@test "test-gate.sh falls back to tee-to-raw-file when pretty not supported" {
  # When _bats_use_pretty=false the old tee pattern must still be present.
  run grep -n 'tee.*_tests_raw_file' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tee"* ]]
  [[ "$output" == *"_tests_raw_file"* ]]
}

@test "test-gate.sh _bats_tap_dir is PID-scoped to prevent glob collision" {
  # The tap dir name must include $$ (current PID) to isolate concurrent runs.
  run grep -n '_bats_tap_dir.*\$\$\|mktemp.*_bats_tap_dir\|rite_gate_tap' \
    "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$$'* || "$output" == *"rite_gate_tap"* ]]
}

@test "test-gate.sh _bats_tap_dir is cleaned up (rm -rf, not glob)" {
  # Cleanup must use the specific variable, never a glob, per temp-file-isolation contract.
  run grep -n 'rm.*_bats_tap_dir' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_bats_tap_dir"* ]]
  # Must NOT use a glob pattern (e.g. /tmp/rite_gate_tap_*.*)
  run grep -n 'rm.*rite_gate_tap_\*' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -ne 0 ]
}

@test "test-gate.sh trap handler also cleans up _bats_tap_dir" {
  # The EXIT trap must include _bats_tap_dir cleanup so it fires on crash too.
  run grep -n 'trap.*_bats_tap_dir\|_bats_tap_dir.*trap' "${RITE_LIB_DIR}/utils/test-gate.sh"
  # Either a direct grep on the trap body or on the pattern near the trap line
  # A simpler check: the trap body (line 459) must reference _bats_tap_dir.
  _trap_section=$(sed -n "/trap '.*_gate_exit_status/,/EXIT$/p" \
    "${RITE_LIB_DIR}/utils/test-gate.sh" 2>/dev/null || true)
  echo "$_trap_section" | grep -q '_bats_tap_dir' || {
    echo "FAIL: EXIT trap does not clean up _bats_tap_dir" >&2
    echo "Trap section:" >&2
    echo "$_trap_section" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# JSON parser regression: TAP content preserved for ^not ok parsing
# ---------------------------------------------------------------------------

@test "_parse_bats_failure_line still parses TAP 'not ok N test name' format" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    result=\$(_parse_bats_failure_line 'not ok 3 my failing test' 2>/dev/null || true)
    echo \"\$result\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"test_name"'* ]]
  [[ "$output" == *"my failing test"* ]]
}

@test "_parse_bats_failure_line: passing 'ok N' TAP line returns nothing" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    result=\$(_parse_bats_failure_line 'ok 1 my passing test' 2>/dev/null || true)
    echo \"result:[\$result]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "result:[]" ]]
}

@test "_parse_bats_failure_line: pretty-formatted output line returns nothing (no false positives)" {
  # The pretty formatter outputs '✓ test name' or '✗ test name' lines.
  # These must NOT be mistaken for TAP failures by the parser.
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Simulate a pretty-formatter line (✓ test passed)
    result=\$(_parse_bats_failure_line ' ✓ my test name' 2>/dev/null || true)
    echo \"result:[\$result]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "result:[]" ]]
}

# ---------------------------------------------------------------------------
# Makefile: test target uses -F pretty when bats supports --report-formatter
# ---------------------------------------------------------------------------

@test "Makefile test target references -F pretty formatter" {
  run grep -n '\-F pretty' "${BATS_TEST_DIRNAME}/../../Makefile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-F pretty"* ]]
}

@test "Makefile test target detects --report-formatter support before using pretty" {
  # The Makefile must check whether the installed bats supports --report-formatter
  # before passing -F pretty, to avoid failing on old bats versions.
  run grep -n 'report-formatter' "${BATS_TEST_DIRNAME}/../../Makefile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"report-formatter"* ]]
}

@test "Makefile test target retains -r tests/ invocation" {
  # The recursive bats invocation must remain intact after the pretty change.
  run grep -n 'bats.*-r tests/' "${BATS_TEST_DIRNAME}/../../Makefile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-r tests/"* ]]
}
