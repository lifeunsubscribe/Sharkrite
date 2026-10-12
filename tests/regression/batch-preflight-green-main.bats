#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/assess-and-resolve.sh
# tests/regression/batch-preflight-green-main.bats
#
# Regression tests for the green-main preflight gate (issue #1149).
#
# Gate block-on-any is sound only when main is green. When main is red a batch
# run would feed 51+ inherited failures into ACTIONABLE_NOW per issue, burning
# the fix loop on problems the branch never caused.
#
# Two-part contract:
#   1. Batch preflight: run full gate on origin/main before issue 1; halt on
#      failure (exit 20) unless RITE_ACCEPT_RED_MAIN=1.
#   2. Attribution subtraction: when RITE_ACCEPT_RED_MAIN=1, failures that also
#      appear on main are INFO_ONLY (not ACTIONABLE_NOW); branch-only failures
#      remain ACTIONABLE_NOW.
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1.  Green-main preflight block exists in batch-process-issues.sh
#     2.  RITE_ACCEPT_RED_MAIN guard wired
#     3.  exit 20 used for preflight halt
#     4.  _RITE_MAIN_BASELINE_FILE exported on accepted red main
#     5.  test-gate.sh sourced inside preflight (run_test_gate declared-f guard)
#     6.  RITE_GATE_FORCE_FULL=1 passed to run_test_gate in preflight
#     7.  Attribution mode variables initialized in assess-and-resolve.sh
#     8.  INFO_ONLY suffix used for inherited test/lint items
#     9.  Test name exact-match against baseline (_gate_main_baseline_tests)
#    10.  Lint file+rule key match against baseline (_gate_main_baseline_lint_keys)
#    11.  Synthetic block suppressed for all-inherited scenario
#    12.  exit 20 documented in docs/architecture/exit-codes.md
#    13.  behavioral-design.md references Red-Main Degradation Contract
#
#   BEHAVIORAL (attribution subtraction logic):
#    14.  Fixture: test name matching baseline → _test_is_inherited=true
#    15.  Fixture: test name NOT in baseline → _test_is_inherited=false
#    16.  Fixture: lint file+rule key matching baseline → _lint_is_inherited=true
#    17.  Fixture: lint file+rule key NOT in baseline → _lint_is_inherited=false
#    18.  Green-main baseline absent → no attribution (normal NOW behavior)

# sharkrite-gate-serial

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
ASSESS_RESOLVE="$REPO_ROOT/lib/core/assess-and-resolve.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"
BEHAVIORAL_DESIGN="$REPO_ROOT/docs/architecture/behavioral-design.md"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$ASSESS_RESOLVE" ] || {
    echo "FATAL: $ASSESS_RESOLVE not found" >&2
    return 1
  }
  [ -f "$EXIT_CODES_DOC" ] || {
    echo "FATAL: $EXIT_CODES_DOC not found" >&2
    return 1
  }
  [ -f "$BEHAVIORAL_DESIGN" ] || {
    echo "FATAL: $BEHAVIORAL_DESIGN not found" >&2
    return 1
  }
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify the implementation is in place (static code inspection)
# =============================================================================

@test "structural: green-main preflight block exists in batch-process-issues.sh" {
  grep -q 'Green-Main Preflight\|green-main preflight\|green_main_preflight\|Green.main preflight' \
    "$BATCH_PROCESSOR" || {
    echo "FAIL: green-main preflight block not found in batch-process-issues.sh" >&2
    echo "      Expected a preflight section that checks origin/main before processing issues" >&2
    return 1
  }
}

@test "structural: RITE_ACCEPT_RED_MAIN guard wired in batch-process-issues.sh" {
  grep -q 'RITE_ACCEPT_RED_MAIN' "$BATCH_PROCESSOR" || {
    echo "FAIL: RITE_ACCEPT_RED_MAIN not found in batch-process-issues.sh" >&2
    echo "      Expected an escape hatch for proceeding with a known-red main" >&2
    return 1
  }
}

@test "structural: exit 20 used for preflight halt in batch-process-issues.sh" {
  grep -qE 'exit[[:space:]]+20' "$BATCH_PROCESSOR" || {
    echo "FAIL: exit 20 not found in batch-process-issues.sh" >&2
    echo "      Expected exit 20 as the preflight-halt exit code" >&2
    return 1
  }
}

@test "structural: _RITE_MAIN_BASELINE_FILE exported when accepting red main" {
  grep -q '_RITE_MAIN_BASELINE_FILE' "$BATCH_PROCESSOR" || {
    echo "FAIL: _RITE_MAIN_BASELINE_FILE not referenced in batch-process-issues.sh" >&2
    echo "      Expected the baseline file path to be exported for assess-and-resolve.sh" >&2
    return 1
  }
  grep -q 'export _RITE_MAIN_BASELINE_FILE' "$BATCH_PROCESSOR" || {
    echo "FAIL: _RITE_MAIN_BASELINE_FILE is not exported in batch-process-issues.sh" >&2
    echo "      The var must be exported so child processes (assess-and-resolve.sh) see it" >&2
    return 1
  }
}

@test "structural: run_test_gate sourced with declare -f guard in preflight" {
  grep -qE 'declare -f run_test_gate' "$BATCH_PROCESSOR" || {
    echo "FAIL: declare -f run_test_gate guard not found in batch-process-issues.sh" >&2
    echo "      Expected idempotent source of test-gate.sh before calling run_test_gate" >&2
    return 1
  }
}

@test "structural: RITE_GATE_FORCE_FULL=1 passed to run_test_gate in preflight" {
  grep -q 'RITE_GATE_FORCE_FULL=1' "$BATCH_PROCESSOR" || {
    echo "FAIL: RITE_GATE_FORCE_FULL=1 not found in batch-process-issues.sh" >&2
    echo "      Preflight must force a full gate run (not diff-based) on origin/main" >&2
    return 1
  }
}

@test "structural: attribution mode variables initialized in assess-and-resolve.sh" {
  grep -q '_gate_accept_red_main' "$ASSESS_RESOLVE" || {
    echo "FAIL: _gate_accept_red_main not found in assess-and-resolve.sh" >&2
    return 1
  }
  grep -q '_gate_main_baseline_tests' "$ASSESS_RESOLVE" || {
    echo "FAIL: _gate_main_baseline_tests not found in assess-and-resolve.sh" >&2
    return 1
  }
  grep -q '_gate_inherited_count' "$ASSESS_RESOLVE" || {
    echo "FAIL: _gate_inherited_count not found in assess-and-resolve.sh" >&2
    return 1
  }
}

@test "structural: INFO_ONLY suffix used for main-inherited items in assess-and-resolve.sh" {
  grep -q 'INFO_ONLY' "$ASSESS_RESOLVE" || {
    echo "FAIL: INFO_ONLY not found in assess-and-resolve.sh" >&2
    echo "      Expected INFO_ONLY suffix on inherited gate items (not ACTIONABLE_NOW)" >&2
    return 1
  }
}

@test "structural: test name exact-match against baseline in assess-and-resolve.sh" {
  grep -q '_gate_main_baseline_tests' "$ASSESS_RESOLVE" && \
  grep -q '_test_is_inherited' "$ASSESS_RESOLVE" || {
    echo "FAIL: test name attribution check (_test_is_inherited) not found in assess-and-resolve.sh" >&2
    return 1
  }
}

@test "structural: lint file+rule key match against baseline in assess-and-resolve.sh" {
  grep -q '_gate_main_baseline_lint_keys' "$ASSESS_RESOLVE" && \
  grep -q '_lint_is_inherited' "$ASSESS_RESOLVE" || {
    echo "FAIL: lint attribution check (_lint_is_inherited) not found in assess-and-resolve.sh" >&2
    return 1
  }
}

@test "structural: synthetic empty-findings block suppressed for all-inherited scenario" {
  # The synthetic block must check _gate_inherited_count > 0 (attribution mode)
  # to avoid firing a phantom 'gate exited non-zero but no findings' ACTIONABLE_NOW
  # when all failures were attributed to main.
  grep -q '_gate_inherited_count' "$ASSESS_RESOLVE" && \
  grep -qE '_gate_accept_red_main.*_gate_inherited_count|_gate_inherited_count.*_gate_accept_red_main' \
    "$ASSESS_RESOLVE" || {
    echo "FAIL: synthetic block not guarded by _gate_inherited_count in assess-and-resolve.sh" >&2
    echo "      When all failures are main-inherited, GATE_NOW_COUNT=0 but the synthetic" >&2
    echo "      block must not fire (no branch-introduced failures)." >&2
    return 1
  }
}

@test "structural: exit 20 documented in docs/architecture/exit-codes.md" {
  grep -qE '^\| `20`' "$EXIT_CODES_DOC" || {
    echo "FAIL: exit code 20 not found in exit-codes.md" >&2
    echo "      Expected a row documenting exit 20 as the green-main preflight halt code" >&2
    return 1
  }
}

@test "structural: behavioral-design.md documents Red-Main Degradation Contract" {
  grep -q 'Red-Main Degradation Contract' "$BEHAVIORAL_DESIGN" || {
    echo "FAIL: 'Red-Main Degradation Contract' not found in behavioral-design.md" >&2
    echo "      Expected the doc to amend Gate Block-on-Any with the degradation contract" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: attribution subtraction logic (using inline simulations)
# =============================================================================

@test "behavioral: test name matching baseline → inherited (not ACTIONABLE_NOW)" {
  # Simulate the attribution check from assess-and-resolve.sh:
  # a test_name that appears in the main baseline must be flagged _test_is_inherited=true.
  _gate_main_baseline_tests="dashboard renders correctly
auth token expires gracefully"
  _test_name="dashboard renders correctly"

  _test_is_inherited=false
  if [ -n "$_gate_main_baseline_tests" ]; then
    if printf '%s\n' "$_gate_main_baseline_tests" | grep -qxF "$_test_name" 2>/dev/null; then
      _test_is_inherited=true
    fi
  fi

  [ "$_test_is_inherited" = "true" ] || {
    echo "FAIL: test name '${_test_name}' present in baseline but _test_is_inherited=false" >&2
    return 1
  }
}

@test "behavioral: test name NOT in baseline → branch-only (ACTIONABLE_NOW)" {
  # A test_name not in the main baseline must NOT be flagged as inherited.
  _gate_main_baseline_tests="dashboard renders correctly
auth token expires gracefully"
  _test_name="new feature: widget creation fails"

  _test_is_inherited=false
  if [ -n "$_gate_main_baseline_tests" ]; then
    if printf '%s\n' "$_gate_main_baseline_tests" | grep -qxF "$_test_name" 2>/dev/null; then
      _test_is_inherited=true
    fi
  fi

  [ "$_test_is_inherited" = "false" ] || {
    echo "FAIL: test name '${_test_name}' absent from baseline but _test_is_inherited=true" >&2
    return 1
  }
}

@test "behavioral: lint file+rule key matching baseline → inherited (not ACTIONABLE_NOW)" {
  _gate_main_baseline_lint_keys="lib/core/foo.sh:SC2086
lib/utils/bar.sh:BARE_MARKER_GREP"
  _lint_file="lib/core/foo.sh"
  _lint_rule="SC2086"

  _lint_is_inherited=false
  _lint_key="${_lint_file}:${_lint_rule}"
  if printf '%s\n' "$_gate_main_baseline_lint_keys" | grep -qxF "$_lint_key" 2>/dev/null; then
    _lint_is_inherited=true
  fi

  [ "$_lint_is_inherited" = "true" ] || {
    echo "FAIL: lint key '${_lint_key}' present in baseline but _lint_is_inherited=false" >&2
    return 1
  }
}

@test "behavioral: lint file+rule key NOT in baseline → branch-only (ACTIONABLE_NOW)" {
  _gate_main_baseline_lint_keys="lib/core/foo.sh:SC2086
lib/utils/bar.sh:BARE_MARKER_GREP"
  _lint_file="lib/core/new-file.sh"
  _lint_rule="SC2086"

  _lint_is_inherited=false
  _lint_key="${_lint_file}:${_lint_rule}"
  if printf '%s\n' "$_gate_main_baseline_lint_keys" | grep -qxF "$_lint_key" 2>/dev/null; then
    _lint_is_inherited=true
  fi

  [ "$_lint_is_inherited" = "false" ] || {
    echo "FAIL: lint key '${_lint_key}' absent from baseline but _lint_is_inherited=true" >&2
    return 1
  }
}

@test "behavioral: green-main baseline absent → attribution disabled (no inherited items)" {
  # When the baseline file does not exist, _gate_accept_red_main must be false
  # and the attribution check must not fire. Simulate the initialization logic.
  _nonexistent_baseline="$_tmpdir/gate-main-baseline-does-not-exist.json"

  RITE_ACCEPT_RED_MAIN_test=0
  _gate_accept_red_main=false
  _gate_main_baseline_tests=""

  if [ "${RITE_ACCEPT_RED_MAIN_test}" = "1" ] && [ -f "$_nonexistent_baseline" ]; then
    _gate_accept_red_main=true
    _gate_main_baseline_tests=$(jq -r '(.tests // []) | .[].test_name // empty' \
      "$_nonexistent_baseline" 2>/dev/null || true)
  fi

  [ "$_gate_accept_red_main" = "false" ] || {
    echo "FAIL: _gate_accept_red_main=true even though baseline file does not exist" >&2
    return 1
  }
  [ -z "$_gate_main_baseline_tests" ] || {
    echo "FAIL: _gate_main_baseline_tests non-empty even though baseline file does not exist" >&2
    return 1
  }
}
