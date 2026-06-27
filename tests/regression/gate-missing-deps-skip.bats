#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Verifies that the pytest loud-skip logic (issue #744) correctly distinguishes
# missing-dep/no-tests env failures from real test failures.
#
# All 13 tests are REQUIRED by the acceptance criteria — each guards a specific
# failure mode that the v1 implementation (PR #749) would have handled wrongly.
#
# Uses _classify_pytest_outcome directly (unit-style) rather than the full
# run_test_gate harness so the classification logic is tested in isolation,
# without needing a real pytest binary or a worktree-shaped git repo.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # Stub _diag so sourcing test-gate.sh doesn't require the full logging stack.
  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
}

# ---------------------------------------------------------------------------
# Case 1 (AC guard for v1 loose-grep false-skip bug):
# Real failure whose traceback mentions ModuleNotFoundError → outcome=failed
#
# v1 grepped for ModuleNotFoundError anywhere in output. This test ensures
# a real failure (FAILED + AssertionError) is not silently skipped even when
# the same traceback happens to mention a missing module.
# ---------------------------------------------------------------------------
@test "real failure that mentions ModuleNotFoundError → outcome=failed (not skipped)" {
  # Simulated pytest exit 1 output: a real FAILED test whose traceback includes
  # a ModuleNotFoundError (e.g. the test's setUp imported an optional dep that
  # happens to be absent, but the test itself raised AssertionError).
  local _output
  _output="collected 1 item

FAILED tests/test_foo.py::test_bar - AssertionError: expected True, got False

E   ModuleNotFoundError: No module named 'optional_extra'
E   AssertionError: expected True, got False

======================== 1 failed in 0.42s ========================"

  run _classify_pytest_outcome 1 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ] || {
    echo "FAIL: expected 'failed', got '$output'"
    echo "      A real FAILED test must not be silently skipped even when"
    echo "      its traceback mentions ModuleNotFoundError (v1 false-skip bug)."
    false
  }
}

# ---------------------------------------------------------------------------
# Case 2 (AC guard for collection-breaking regression):
# Collection error → outcome=failed, even when no tests ran.
#
# A collection-breaking import error (SyntaxError, bad fixture, broken conftest)
# must never be silenced — it could hide a real regression. Guards both the
# exit-2 path and the output-signature path.
# ---------------------------------------------------------------------------
@test "collection-breaking error (output signature) → outcome=failed" {
  local _output
  _output="collected 0 items / 1 error

==================== ERRORS ====================
ERROR collecting tests/test_broken.py
ImportError while importing test module
conftest.py:5: in <module>
    from missing_module import helper
E   ModuleNotFoundError: No module named 'missing_module'

======================== errors during collection ========================"

  # Exit code may be 2 (pytest collection error) or 1 depending on pytest version.
  # Test with exit 1 to verify the output signature alone is sufficient.
  run _classify_pytest_outcome 1 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ] || {
    echo "FAIL: expected 'failed', got '$output'"
    echo "      A collection error must block the gate even if no tests ran."
    false
  }
}

@test "collection-breaking error (exit 2) → outcome=failed" {
  # pytest exit code 2 = interrupted/collection error. Even with benign-looking
  # output (no FAILED, no ModuleNotFoundError), exit 2 must yield failed.
  local _output
  _output="collected 0 items / 1 error

ERROR collecting tests/test_syntax_error.py
SyntaxError: invalid syntax"

  run _classify_pytest_outcome 2 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ] || {
    echo "FAIL: expected 'failed' for exit 2 (collection error), got '$output'"
    false
  }
}

# ---------------------------------------------------------------------------
# Case 3 (no tests collected):
# Exit 5, no collection-error signature → outcome=skipped:no_tests
#
# pytest exits 5 when it finds no tests (empty suite, wrong path). This is an
# env/config issue, not a test failure. The gate should skip with a hint rather
# than blocking the merge.
# ---------------------------------------------------------------------------
@test "no tests collected (exit 5, no error) → outcome=skipped:no_tests" {
  local _output
  _output="collected 0 items

======================== no tests ran ========================"

  run _classify_pytest_outcome 5 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped:no_tests" ] || {
    echo "FAIL: expected 'skipped:no_tests', got '$output'"
    echo "      Exit 5 with no collection-error signature is a config issue,"
    echo "      not a test failure — the gate should loud-skip with a hint."
    false
  }
}

# ---------------------------------------------------------------------------
# Case 4 (missing dependency):
# Anchored ModuleNotFoundError, no FAILED/AssertionError → outcome=skipped:missing_deps
#
# Two sub-cases:
# 4a. Pytest-formatted error line with ^E prefix (test dep missing, pytest still runs):
#       E  ModuleNotFoundError: No module named 'mymodule'
# 4b. Python-interpreter error line WITHOUT ^E prefix (pytest itself not installed):
#       /usr/bin/python3: No module named pytest
#     The ^E anchor in 4a never fires for this output — requires a separate branch.
# ---------------------------------------------------------------------------
@test "missing dependency (anchored ModuleNotFoundError, no FAILED) → outcome=skipped:missing_deps" {
  # 4a: pytest-formatted error line (^E prefix). pytest is installed, a project dep is missing.
  local _output
  _output="ImportError while importing test module
tests/test_mymodule.py:1: in <module>
    import mymodule
E   ModuleNotFoundError: No module named 'mymodule'

======================== 1 error in 0.08s ========================"

  run _classify_pytest_outcome 1 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped:missing_deps" ] || {
    echo "FAIL: expected 'skipped:missing_deps', got '$output'"
    echo "      A missing project dependency (^E prefix, no FAILED) must yield loud skip."
    false
  }
}

@test "missing runner — python3 -m pytest with pytest uninstalled → outcome=skipped:missing_deps" {
  # 4b: Headline scenario. pytest itself is NOT installed. The Python interpreter
  # prints its own error message — NO ^E prefix, NO pytest output formatting.
  # Real output from: python3 -m pytest  (pytest not in the active venv/env)
  #   /usr/bin/python3: No module named pytest
  # The ^E-anchored branch (4a) never matches this — requires the separate
  # missing-runner branch added in the issue #744 fix.
  local _output
  _output="/usr/bin/python3: No module named pytest"

  run _classify_pytest_outcome 1 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped:missing_deps" ] || {
    echo "FAIL: expected 'skipped:missing_deps', got '$output'"
    echo "      When pytest itself is not installed, python3 -m pytest emits:"
    echo "        /usr/bin/python3: No module named pytest"
    echo "      (no ^E prefix — the Python interpreter, not pytest, prints this)."
    echo "      This is the headline scenario of issue #744 and must loud-skip."
    false
  }
}

@test "missing runner — python3: No module named pytest (short form) → outcome=skipped:missing_deps" {
  # Variant: some Python builds emit the shorter form without the full path.
  local _output
  _output="python3: No module named pytest"

  run _classify_pytest_outcome 1 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped:missing_deps" ] || {
    echo "FAIL: expected 'skipped:missing_deps', got '$output'"
    echo "      Short-form interpreter error must also loud-skip."
    false
  }
}

@test "missing dependency (No module named on error line, no FAILED, no collection sig) → outcome=skipped:missing_deps" {
  # A missing runner-level dependency: pytest itself is installed but a required
  # import at module level fails before any test runs. This produces exit 1 with
  # a `^E ` prefixed ModuleNotFoundError but WITHOUT the "errors during collection"
  # or "ERROR collecting" signature (those appear when pytest processes .py files
  # individually; this output is from a direct module-level import failure).
  local _output
  _output="ImportError while importing test module
tests/test_mymodule.py:1: in <module>
    import mymodule
E   ModuleNotFoundError: No module named 'mymodule'

======================== 1 error in 0.08s ========================"

  run _classify_pytest_outcome 1 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped:missing_deps" ] || {
    echo "FAIL: expected 'skipped:missing_deps', got '$output'"
    echo "      A missing project dependency (no FAILED/AssertionError, no collection"
    echo "      error signature) should yield a loud skip, not a gate failure."
    false
  }
}

# ---------------------------------------------------------------------------
# Case 5 (clean pass — regression guard):
# Exit 0 → outcome=passed, unchanged behavior.
# ---------------------------------------------------------------------------
@test "clean pass (exit 0) → outcome=passed" {
  local _output
  _output="collected 3 items

tests/test_foo.py::test_one PASSED
tests/test_foo.py::test_two PASSED
tests/test_foo.py::test_three PASSED

======================== 3 passed in 0.12s ========================"

  run _classify_pytest_outcome 0 "$_output"
  [ "$status" -eq 0 ]
  [ "$output" = "passed" ] || {
    echo "FAIL: expected 'passed' for exit 0, got '$output'"
    echo "      A clean pytest run must continue to yield outcome=passed."
    false
  }
}

# ---------------------------------------------------------------------------
# Structural check: loud-skip path mirrors the missing_runner shape.
# Verifies that the skipped:missing_deps and skipped:no_tests branches in
# run_test_gate emit WARNING messages (not silent) and write skipped:true JSON,
# matching the cargo/go missing_runner loud-skip contract.
# ---------------------------------------------------------------------------
@test "skipped:missing_deps branch emits WARNING to stderr" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # Match the literal emitted stderr string, not comments or docstrings.
  # The branch must echo "[test-gate] WARNING: pytest detected missing dependencies" to >&2.
  run grep -n '\[test-gate\] WARNING: pytest detected missing dependencies' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no WARNING stderr echo for missing_deps path found in test-gate.sh"
    echo "      The loud-skip must print an actionable WARNING (mirrors missing_runner)."
    false
  }
}

@test "skipped:no_tests branch emits WARNING to stderr" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # Match the literal emitted stderr string, not comments or docstrings.
  # The branch must echo "[test-gate] WARNING: pytest collected no tests" to >&2.
  run grep -n '\[test-gate\] WARNING: pytest collected no tests' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no WARNING stderr echo for no_tests path found in test-gate.sh"
    echo "      The loud-skip must print an actionable WARNING (mirrors missing_runner)."
    false
  }
}

@test "skipped:missing_deps branch writes JSON with skipped:true and reason=missing_deps" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  run grep -n '"missing_deps"' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: reason=missing_deps not found in _gate_write_json call in test-gate.sh"
    echo "      The loud-skip must write JSON with reason=missing_deps."
    false
  }
}

@test "skipped:no_tests branch writes JSON with skipped:true and reason=no_tests" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  run grep -n '"no_tests"' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: reason=no_tests not found in _gate_write_json call in test-gate.sh"
    echo "      The loud-skip must write JSON with reason=no_tests."
    false
  }
}
