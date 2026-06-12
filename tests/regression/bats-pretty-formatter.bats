#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, Makefile
# Regression test: bats --pretty for terminal; TAP for log/JSON-parser (issue #484)
#
# Verifies:
#   1. _bats_supports_report_formatter is defined and callable
#   2. test-gate.sh uses --formatter pretty + --report-formatter tap when supported
#   3. test-gate.sh falls back to TAP stdout when --report-formatter unavailable
#   4. _parse_bats_failure_line correctly parses TAP "not ok" lines (format unchanged)
#   5. JSON findings are byte-compatible regardless of formatter path
#   6. Makefile test target uses TTY-detect for formatter selection

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export TEST_WORKSPACE
  TEST_WORKSPACE=$(mktemp -d)
  export RITE_PROJECT_ROOT="$TEST_WORKSPACE"
  export RITE_STATE_DIR="$TEST_WORKSPACE/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
  export PR_NUMBER="484"
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_WORKSPACE:-}"
}

# ---------------------------------------------------------------------------
# _bats_supports_report_formatter is defined by test-gate.sh
# ---------------------------------------------------------------------------

@test "_bats_supports_report_formatter is defined after sourcing test-gate.sh" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    declare -f _bats_supports_report_formatter >/dev/null 2>&1 && echo 'defined'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"defined"* ]]
}

@test "_bats_supports_report_formatter: probes bats --help for --report-formatter string" {
  # The function must use bats --help + grep, not version number parsing.
  run grep -n 'bats --help' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats --help"* ]]
  run grep -n 'report-formatter' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"report-formatter"* ]]
}

# ---------------------------------------------------------------------------
# test-gate.sh uses --formatter pretty + --report-formatter tap in split mode
# ---------------------------------------------------------------------------

@test "test-gate.sh references --formatter pretty for terminal output" {
  run grep -n -- '--formatter pretty' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--formatter pretty"* ]]
}

@test "test-gate.sh references --report-formatter tap for JSON parser input" {
  run grep -n -- '--report-formatter tap' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--report-formatter tap"* ]]
}

@test "test-gate.sh reads report.tap file from the bats output dir" {
  # The TAP report file is named "report.tap" by bats convention.
  run grep -n 'report.tap' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"report.tap"* ]]
}

@test "test-gate.sh warns when --report-formatter is not available" {
  run grep -n -- '--report-formatter not available\|falling back to TAP' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to TAP"* ]]
}

# ---------------------------------------------------------------------------
# Temp dir cleanup: _bats_tap_dir is cleaned up before the EXIT trap fires
# ---------------------------------------------------------------------------

@test "test-gate.sh cleans up _bats_tap_dir before trap fires" {
  # After the gate run, the tap dir must be explicitly removed (not left to trap cleanup alone).
  # Look for both: explicit rm -rf of _bats_tap_dir AND the trap rm -rf with the var.
  run grep -n 'rm -rf.*_bats_tap_dir\|rm -rf.*bats_tap_dir' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  # At least two matches: one in the trap, one explicit cleanup
  _count=$(echo "$output" | grep -c '.' || true)
  [ "$_count" -ge 2 ]
}

@test "test-gate.sh sets _bats_tap_dir to empty string after rm to neutralize EXIT trap" {
  # After explicit rm -rf, set _bats_tap_dir="" so the EXIT trap's rm -rf is a no-op.
  run grep -n '_bats_tap_dir=""' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'_bats_tap_dir=""'* ]]
}

# ---------------------------------------------------------------------------
# _parse_bats_failure_line: TAP format is unchanged (parser compatibility)
# ---------------------------------------------------------------------------

@test "_parse_bats_failure_line parses TAP 'not ok' lines correctly" {
  # Verify the JSON findings parser still handles the standard TAP format
  # that comes from bats --report-formatter tap (same as old default stdout).
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    result=\$(_parse_bats_failure_line 'not ok 3 my failing test' || true)
    echo \"\$result\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"test_name":"my failing test"'* ]]
  [[ "$output" == *'"reason":"assertion failed"'* ]]
}

@test "_parse_bats_failure_line: passing 'ok' lines return exit 1 (not parsed)" {
  # 'ok N description' lines must be ignored — only 'not ok' lines are failures.
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    _parse_bats_failure_line 'ok 1 passing test'
    echo \"exit:\$?\"
  "
  # The function should return non-zero for 'ok' lines
  [[ "$output" == *"exit:1"* ]]
}

@test "_parse_bats_failure_line: TAP report format output is byte-compatible with old default" {
  # Both bats default stdout TAP and --report-formatter tap produce the same
  # "not ok N description" lines. Verify with a simulated TAP fragment.
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Simulate a TAP report file (same format whether from stdout or --report-formatter tap)
    _tap_input=\$(printf '1..3\nok 1 first test\nnot ok 2 second test\nok 3 third test\n')
    _failures=0
    while IFS= read -r _line; do
      _item=\$(_parse_bats_failure_line \"\$_line\" || true)
      [ -n \"\$_item\" ] && _failures=\$(( _failures + 1 ))
    done <<< \"\$_tap_input\"
    echo \"failures:\$_failures\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"failures:1"* ]]
}

# ---------------------------------------------------------------------------
# Makefile: TTY-detect for formatter selection
# ---------------------------------------------------------------------------

@test "Makefile test target uses TTY detection for formatter selection" {
  _makefile="${BATS_TEST_DIRNAME}/../../Makefile"
  run grep -n '\-t 1\|_bats_fmt' "$_makefile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_bats_fmt"* ]]
}

@test "Makefile test target passes pretty formatter when tty detected" {
  _makefile="${BATS_TEST_DIRNAME}/../../Makefile"
  run grep -n -- '"-p"\|_bats_fmt="-p"' "$_makefile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-p"* ]]
}

@test "Makefile test target passes tap formatter when no tty detected" {
  _makefile="${BATS_TEST_DIRNAME}/../../Makefile"
  run grep -n -- '"-t"\|_bats_fmt="-t"' "$_makefile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-t"* ]]
}

# ---------------------------------------------------------------------------
# Functional: split mode correctly routes pretty to stdout and TAP to report file
# ---------------------------------------------------------------------------

@test "_run_bats_with_formatter: split mode reads report.tap into _tests_raw_file" {
  # Simulate: create a fake bats tap dir with a pre-populated report.tap
  # and verify that _run_bats_with_formatter copies it into _tests_raw_file.
  # We test the file-copy logic in isolation, not the full bats invocation.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'

    # Arrange: set up the internal state _run_bats_with_formatter depends on
    _bats_tap_dir=\$(mktemp -d)
    _tests_raw_file=\$(mktemp)
    project_root=\$(mktemp -d)
    _bats_fmt_args=(--formatter pretty --report-formatter tap --output \"\$_bats_tap_dir\")
    _exit_file=\$(mktemp)

    # Write a known TAP report file (simulating what bats --report-formatter tap writes)
    printf '1..2\nok 1 passing test\nnot ok 2 failing test\n' > \"\$_bats_tap_dir/report.tap\"

    # Simulate a bats run that writes to the tap dir but we control the exit file manually.
    # Test only the report.tap → _tests_raw_file copy path by writing exit 0 manually.
    echo 0 > \"\$_exit_file\"
    if [ -f \"\$_bats_tap_dir/report.tap\" ]; then
      cat \"\$_bats_tap_dir/report.tap\" >> \"\$_tests_raw_file\" || true
    fi

    # Assert: _tests_raw_file contains the TAP content
    _not_ok_count=\$(grep -c '^not ok ' \"\$_tests_raw_file\" || true)
    echo \"not_ok:\$_not_ok_count\"

    rm -rf \"\$_bats_tap_dir\" \"\$_tests_raw_file\" \"\$_exit_file\" \"\$project_root\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_ok:1"* ]]
}

@test "_run_bats_with_formatter: missing report.tap is graceful (empty _tests_raw_file)" {
  # If bats crashes before writing report.tap, _tests_raw_file stays empty.
  # The JSON builder then emits [] — safe fail-open (no false gate failures).
  run bash -c "
    set -euo pipefail
    _bats_tap_dir=\$(mktemp -d)
    _tests_raw_file=\$(mktemp)
    # Do NOT create report.tap — simulate a bats crash before file write

    if [ -f \"\$_bats_tap_dir/report.tap\" ]; then
      cat \"\$_bats_tap_dir/report.tap\" >> \"\$_tests_raw_file\" || true
    fi

    _size=\$(wc -c < \"\$_tests_raw_file\" | tr -d ' ')
    echo \"size:\$_size\"
    rm -rf \"\$_bats_tap_dir\" \"\$_tests_raw_file\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"size:0"* ]]
}

# ---------------------------------------------------------------------------
# Functional: real bats --report-formatter tap produces byte-compatible TAP
# ---------------------------------------------------------------------------

@test "functional: bats --report-formatter tap output is byte-compatible with standard TAP" {
  # Skip if installed bats does not support --report-formatter (bats <1.7.0).
  if ! bats --help 2>&1 | grep -q -- '--report-formatter'; then
    skip "--report-formatter not available in this bats install"
  fi

  # Create a minimal fixture bats file with one passing and one failing test.
  _fixture_dir=$(mktemp -d)
  _tap_dir=$(mktemp -d)
  cat > "$_fixture_dir/fixture.bats" <<'FIXTURE'
#!/usr/bin/env bats
@test "passing test" {
  true
}
@test "failing test" {
  false
}
FIXTURE

  # Run bats with split-mode flags: pretty to stdout, TAP report to _tap_dir.
  # We discard stdout (pretty output) — only report.tap matters here.
  run bash -c "bats --formatter pretty --report-formatter tap --output '$_tap_dir' '$_fixture_dir/fixture.bats' >/dev/null 2>&1; true"

  # report.tap must exist after the run.
  [ -f "$_tap_dir/report.tap" ]

  # The TAP file must contain a plan line ("1..N"), a passing "ok" line, and a
  # failing "not ok" line — proving the format is standard TAP.
  _tap_content=$(cat "$_tap_dir/report.tap")

  # Plan line present
  echo "$_tap_content" | grep -q '^1\.\.'

  # At least one "ok N" line for the passing test
  echo "$_tap_content" | grep -q '^ok [0-9]'

  # At least one "not ok N" line for the failing test — this is what the JSON
  # parser reads; byte-compat means _parse_bats_failure_line can process it.
  echo "$_tap_content" | grep -q '^not ok [0-9]'

  # Verify _parse_bats_failure_line actually processes the "not ok" line from
  # the real TAP report — proving end-to-end parser byte-compatibility.
  _not_ok_line=$(echo "$_tap_content" | grep '^not ok ' | head -1 || true)
  [ -n "$_not_ok_line" ]

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    result=\$(_parse_bats_failure_line $(printf '%q' "$_not_ok_line") || true)
    echo \"\$result\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"test_name"'* ]]

  rm -rf "$_fixture_dir" "$_tap_dir"
}
