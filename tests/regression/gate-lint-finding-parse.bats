#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_parse_lint_line|_gate_build_verdict
#
# Tests for structured sharkrite-lint finding parsing (issue #1492).
# Verifies:
#   - sharkrite-lint ✗ violation lines (plain and ANSI-wrapped) parsed into
#     per-item JSON findings with rule/file/line
#   - non-violation lines (warnings, header text) produce no output
#   - _gate_build_verdict produces structured lint[] entries for sharkrite-lint output
#   - a lint infrastructure failure (non-zero exit, no parseable output) is
#     labeled lint_infrastructure_error rather than "no parseable findings"
#   - caller-supplied reason takes precedence over the infrastructure synthesis
#   - bats TAP failure path is unchanged by this feature

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  _diag() { true; }
  export -f _diag 2>/dev/null || true
  # gate-verdict.sh sources gate-runners.sh which needs config; load config first.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
}

# =============================================================================
# _parse_lint_line: sharkrite-lint violation format (no ANSI)
# =============================================================================

@test "_parse_lint_line: sharkrite-lint plain ✗ — extracts rule, file, line" {
  run _parse_lint_line '✗ lib/core/docs-command.sh:3109 - RAW_MARKER_LITERAL: raw marker literal found'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q '"rule":"RAW_MARKER_LITERAL"'
  printf '%s\n' "$output" | grep -q '"file":"lib/core/docs-command.sh"'
  printf '%s\n' "$output" | grep -q '"line":"3109"'
}

@test "_parse_lint_line: sharkrite-lint numeric rule suffix — extracted cleanly" {
  run _parse_lint_line '✗ lib/utils/test-gate.sh:42 - GREP_C_ECHO_ZERO: grep -c already outputs zero'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '"rule":"GREP_C_ECHO_ZERO"'
  printf '%s\n' "$output" | grep -q '"file":"lib/utils/test-gate.sh"'
  printf '%s\n' "$output" | grep -q '"line":"42"'
}

# =============================================================================
# _parse_lint_line: ANSI-wrapped violation (actual print_violation output)
# =============================================================================

@test "_parse_lint_line: sharkrite-lint ANSI-wrapped ✗ — strips ANSI and parses" {
  # Mirrors the actual output of print_violation(): echo -e "${RED}✗${NC} $file:$line - $rule: $message"
  # RED=\033[0;31m  NC=\033[0m
  _ansi_line=$'\033[0;31m✗\033[0m lib/utils/test-gate.sh:42 - GREP_C_ECHO_ZERO: grep -c produces double zero'
  run _parse_lint_line "$_ansi_line"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q '"rule":"GREP_C_ECHO_ZERO"'
  printf '%s\n' "$output" | grep -q '"file":"lib/utils/test-gate.sh"'
  printf '%s\n' "$output" | grep -q '"line":"42"'
}

# =============================================================================
# _parse_lint_line: non-violation lines produce no output
# =============================================================================

@test "_parse_lint_line: sharkrite-lint warning (⚠) is not parsed" {
  # print_warning uses ⚠, not ✗ — warnings don't fail the build
  run _parse_lint_line '⚠ lib/utils/test-gate.sh:10 - SOME_RULE: informational warning'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_parse_lint_line: sharkrite-lint header line is not parsed" {
  run _parse_lint_line 'Running Sharkrite custom lint rules...'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_parse_lint_line: sharkrite-lint summary line is not parsed" {
  run _parse_lint_line '✗ Found 2 violation(s)'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# =============================================================================
# _gate_build_verdict: sharkrite-lint violation → structured lint[] findings
# =============================================================================

@test "_gate_build_verdict: sharkrite-lint violation → lint[]=1, correct rule/file/line" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '✗ lib/core/docs-command.sh:3109 - RAW_MARKER_LITERAL: raw marker literal found\n' \
    > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub test\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"; [ "$output" = "1" ]
  run jq -r '.lint | length' "$_out"; [ "$output" = "1" ]
  run jq -r '.lint[0].rule' "$_out"; [ "$output" = "RAW_MARKER_LITERAL" ]
  run jq -r '.lint[0].file' "$_out"; [ "$output" = "lib/core/docs-command.sh" ]
  run jq -r '.lint[0].line' "$_out"; [ "$output" = "3109" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict: multiple sharkrite-lint violations → lint[] has all items" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  {
    printf '✗ lib/core/docs-command.sh:3109 - RAW_MARKER_LITERAL: first violation\n'
    printf '✗ lib/utils/test-gate.sh:42 - GREP_C_ECHO_ZERO: second violation\n'
  } > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub test\n' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" "" || true

  [ "${_gbv_lint_count:-0}" = "2" ]

  run jq -r '.lint | length' "$_out"
  [ "$output" = "2" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict: sharkrite-lint violation — no reason field set when items parsed" {
  # lint_infrastructure_error synthesis must NOT fire when violations were parsed
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '✗ lib/core/docs-command.sh:3109 - RAW_MARKER_LITERAL: raw marker literal\n' \
    > "$_lint_raw"
  printf '' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" "" || true

  run jq -r '.reason // "none"' "$_out"
  [ "$output" = "none" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

# =============================================================================
# Infrastructure error: lint fails but produces no parseable output
# =============================================================================

@test "_gate_build_verdict: lint infrastructure error → reason=lint_infrastructure_error" {
  # Simulates make lint crashing or producing no parseable violation lines
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf 'make: *** [lint] Error 1\n' > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub test\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"; [ "$output" = "1" ]
  run jq -r '.lint | length' "$_out"; [ "$output" = "0" ]
  run jq -r '.reason' "$_out"; [ "$output" = "lint_infrastructure_error" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict: infrastructure error — caller-supplied reason takes precedence" {
  # run_test_gate may set a reason (e.g. runner_unavailable) before calling _gate_build_verdict;
  # lint_infrastructure_error synthesis must not clobber a caller-supplied reason.
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub test\n' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "runner_unavailable" "" || true

  run jq -r '.reason' "$_out"
  [ "$output" = "runner_unavailable" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

# =============================================================================
# TAP failure path: unchanged by this feature
# =============================================================================

@test "_gate_build_verdict: bats TAP failure path unchanged — tests[]=1 when test fails" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf 'TAP version 13\n1..2\nok 1 passing test\nnot ok 2 failing test\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"; [ "$output" = "1" ]
  run jq -r '.lint | length' "$_out"; [ "$output" = "0" ]
  run jq -r '.tests | length' "$_out"; [ "$output" = "1" ]
  run jq -r '.tests[0].test_name' "$_out"
  [[ "$output" == *"failing test"* ]]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}
