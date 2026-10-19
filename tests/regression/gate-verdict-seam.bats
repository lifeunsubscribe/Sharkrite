#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_build_verdict
#
# Tests for _gate_build_verdict — the pure verdict-assembly seam (#1240).
# Each test calls _gate_build_verdict directly with pre-built fixture files,
# verifying: correct JSON output for each fixture shape, and that the function
# spawns no bats/make/git subprocesses.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  _diag() { true; }
  export -f _diag 2>/dev/null || true
  # gate-verdict.sh sources gate-runners.sh which needs config; load config first.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
}

# _make_lint_raw — write a shellcheck-format lint finding to a file
# Args: $1=output_file  $2=extra_finding (optional second line)
_make_lint_raw() {
  local _f="$1"
  printf 'lib/utils/config.sh:10:5: warning: Backtick subshell deprecated. [SC2006]\n' > "$_f"
  [ -n "${2:-}" ] && printf '%s\n' "$2" >> "$_f"
}

# _make_tests_raw_watchdog — write a post-synthesis watchdog TAP fixture
# (the state _tests_raw_file is in after run_test_gate's watchdog processing).
# Plan 5, 0 reported; one collapsed not-run finding appended by the caller.
_make_tests_raw_watchdog() {
  local _f="$1"
  printf '1..5\n' > "$_f"
  printf 'not ok 1 [tests_not_run] watchdog killed bats group after 1800s — 5 tests not run; root cause is gate runtime, not the tests (reduce selection cost: add # sharkrite-gate-serial to load-heavy files, or scope lint rules with SHARKRITE_LINT_ONLY=N)\n' >> "$_f"
}

# =============================================================================
# Fixture: clean pass — no lint, all tests pass
# =============================================================================

@test "_gate_build_verdict clean pass: exit_code=0, lint=[], tests=[]" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '1..2\nok 1 first test\nok 2 second test\n' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 0 "$_out" "" ""
  [ "$?" -eq 0 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "0" ]

  run jq -r '.lint | length' "$_out"
  [ "$output" = "0" ]

  run jq -r '.tests | length' "$_out"
  [ "$output" = "0" ]

  run jq -r '.skipped' "$_out"
  [ "$output" = "null" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict clean pass: _gbv_lint_count=0" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '1..1\nok 1 passing test\n' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 0 "$_out" "" ""

  [ "${_gbv_lint_count:-unset}" = "0" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

# =============================================================================
# Fixture: lint failure — shellcheck finding, no test failures
# =============================================================================

@test "_gate_build_verdict lint failure: exit_code=1, lint[]=1 finding, tests[]=0" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  _make_lint_raw "$_lint_raw"
  printf '1..1\nok 1 passing test\n' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" ""
  [ "$?" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  run jq -r '.lint | length' "$_out"
  [ "$output" = "1" ]

  run jq -r '.tests | length' "$_out"
  [ "$output" = "0" ]

  run jq -r '.lint[0].rule' "$_out"
  [ "$output" = "SC2006" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict lint failure: _gbv_lint_count=1" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  _make_lint_raw "$_lint_raw"
  printf '' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" ""

  [ "${_gbv_lint_count:-unset}" = "1" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict lint failure with reason: reason field present in JSON" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  _make_lint_raw "$_lint_raw"
  printf '' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "runner_unavailable" ""

  run jq -r '.reason' "$_out"
  [ "$output" = "runner_unavailable" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

# =============================================================================
# Fixture: watchdog-kill — post-synthesis TAP (plan 5, 0 reported, exit 1
# after run_test_gate converted 124→1 and appended the collapsed finding)
# =============================================================================

@test "_gate_build_verdict watchdog fixture: exit_code=1, tests[]=1 collapsed finding" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  _make_tests_raw_watchdog "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "tests_not_run" ""
  [ "$?" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  run jq -r '.lint | length' "$_out"
  [ "$output" = "0" ]

  run jq -r '.tests | length' "$_out"
  [ "$output" = "1" ]

  run jq -r '.tests[0].reason' "$_out"
  [ "$output" = "tests_not_run" ]

  run jq -r '.tests[0].test_name' "$_out"
  [[ "$output" == *"[tests_not_run]"* ]]
  [[ "$output" == *"watchdog"* ]]
  [[ "$output" == *"5 tests not run"* ]]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict watchdog fixture: byte-identical to inline assembly" {
  # Build the same inputs that run_test_gate's inline assembly used to receive.
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out_seam=$(mktemp)
  printf '' > "$_lint_raw"
  _make_tests_raw_watchdog "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out_seam" "tests_not_run" ""

  # Verify the JSON is valid and has exactly the expected keys/values.
  run jq -e '{exit_code, lint_len: (.lint|length), tests_len: (.tests|length), reason}' "$_out_seam"
  [ "$status" -eq 0 ]

  run jq -r '.exit_code' "$_out_seam"; [ "$output" = "1" ]
  run jq -r '.lint | length' "$_out_seam"; [ "$output" = "0" ]
  run jq -r '.tests | length' "$_out_seam"; [ "$output" = "1" ]
  run jq -r '.reason' "$_out_seam"; [ "$output" = "tests_not_run" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out_seam"
}

# =============================================================================
# Purity: no bats/make/git subprocess invocations
# =============================================================================

@test "_gate_build_verdict spawns no bats/make/git subprocesses" {
  # Use forbidden stubs that exit non-zero — if _gate_build_verdict calls any
  # of them, the subshell exits non-zero (or a forbidden-marker appears in output).
  _stub=$(mktemp -d)
  printf '#!/bin/bash\necho "FORBIDDEN: bats called" >&2; exit 66\n' > "$_stub/bats"
  printf '#!/bin/bash\necho "FORBIDDEN: make called" >&2; exit 66\n' > "$_stub/make"
  printf '#!/bin/bash\necho "FORBIDDEN: git called" >&2; exit 66\n'  > "$_stub/git"
  chmod +x "$_stub/bats" "$_stub/make" "$_stub/git"

  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '1..1\nok 1 test\n' > "$_tests_raw"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/gate-verdict.sh'
    set +u; set +o pipefail
    PATH='${_stub}:\$PATH' _gate_build_verdict '${_lint_raw}' '${_tests_raw}' 0 0 '${_out}' '' ''
  " </dev/null
  [ "$status" -eq 0 ] \
    || fail "status=$status — a forbidden tool (bats/make/git) was likely invoked: $output"

  # Also verify no forbidden marker in output
  ! echo "$output" | grep -q "FORBIDDEN:" \
    || fail "forbidden tool invocation detected in output: $output"

  rm -rf "$_stub" "$_lint_raw" "$_tests_raw" "$_out"
}

# =============================================================================
# head_sha passthrough
# =============================================================================

@test "_gate_build_verdict head_sha embedded in JSON when provided" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 0 "$_out" "" "abc123def456"

  run jq -r '.head_sha' "$_out"
  [ "$output" = "abc123def456" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "_gate_build_verdict no head_sha: field absent from JSON" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 0 "$_out" "" ""

  run jq -r '.head_sha' "$_out"
  [ "$output" = "null" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}
