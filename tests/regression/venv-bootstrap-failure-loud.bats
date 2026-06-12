#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Test suite for issue #12: Gate venv ready message on install success
#
# Verifies that when pip install fails (for base or dev requirements), the
# venv bootstrap in _run_dev_test_gate does NOT print "Venv ready ✅" — it
# should print actionable errors.
#
# DESIGN NOTES (2026-06-12 rewrite):
# - The bootstrap only fires when NO venv exists ([ ! -f .venv/bin/python ]).
#   The original tests pre-created a venv and shimmed its pip/python — the
#   bootstrap therefore skipped entirely and the shims were never invoked;
#   every test was vacuous. Failures are now triggered NATURALLY: a
#   requirements file naming a nonexistent package makes the real pip fail.
# - NEVER write a shim through .venv/bin/python with `cat >`. It is a SYMLINK
#   to the real interpreter; writing through it overwrites the system python
#   binary (live incident 2026-06-09: clobbered Homebrew's python3.14
#   framework binary machine-wide). The natural-failure design removes the
#   need for shims entirely.
# - These tests require network access for pip (real installs / real failures).

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/logging.sh"

  # Create a mock Python project
  export TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO" || exit 1

  # Initialize git repo
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create Python project structure (requirements are set per-test)
  mkdir -p tests
  touch pytest.ini

  # Mock environment variables
  export AUTO_MODE=true
  export RITE_ORCHESTRATED=false
  export RITE_TEST_GATE_SKIP=false

  # config.sh (sourced above, from the sharkrite repo cwd) loads sharkrite's
  # own .rite/config, which sets-and-exports RITE_TEST_CMD (a bats command).
  # _run_dev_test_gate honors RITE_TEST_CMD before auto-detection, which would
  # bypass the pytest branch — and the venv bootstrap under test — entirely.
  unset RITE_TEST_CMD

  # CRITICAL: never let the dev gate spawn a real Claude auto-fix session from
  # inside the test suite. Bootstrap-failure paths fall through to the pytest
  # run (deliberately — see "Don't return 1" comment in _run_dev_test_gate),
  # and a failing pytest in the mock repo would otherwise trigger a live
  # 30-minute LLM session per test.
  export RITE_TEST_GATE_AUTOFIX=false

  # Route _diag/_timing to a log file, not stderr (keeps $output assertions clean)
  unset RITE_VERBOSE

  # Source the function under test (_run_dev_test_gate).
  # RITE_SOURCE_FUNCTIONS_ONLY=1 loads only function definitions without executing
  # the main program body (arg parsing, worktree navigation, Claude dev session).
  # Without this, sourcing launches a real Claude Code session (issue #469).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_LIB_DIR}/core/claude-workflow.sh"
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
}

@test "venv bootstrap: base requirements install failure does NOT print 'Venv ready'" {
  # A nonexistent package makes the real pip fail during bootstrap
  echo "sharkrite-test-nonexistent-package-xyzzy>=1.0" > requirements.txt

  git add . && git commit -m "Initial commit" --quiet

  run _run_dev_test_gate

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain actionable error messaging
  [[ "$output" =~ "Venv bootstrap incomplete" ]]
  [[ "$output" =~ "Base requirements" ]]
}

@test "venv bootstrap: dev requirements install failure does NOT print 'Venv ready'" {
  # Base requirements install fine; dev requirements name a nonexistent package
  echo "pytest>=7.0" > requirements.txt
  echo "sharkrite-test-nonexistent-package-xyzzy>=1.0" > requirements-dev.txt

  git add . && git commit -m "Initial commit" --quiet

  run _run_dev_test_gate

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain error about dev requirements
  [[ "$output" =~ "Dev requirements" ]] || [[ "$output" =~ "requirements-dev.txt" ]]
}

@test "venv bootstrap: success path DOES print 'Venv ready'" {
  echo "pytest>=7.0" > requirements.txt

  # Give pytest something to collect and pass so the gate as a whole succeeds
  cat > tests/test_smoke.py <<'EOF'
def test_smoke():
    assert True
EOF

  git add . && git commit -m "Initial commit" --quiet

  run _run_dev_test_gate

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Venv ready" ]]
  [[ "$output" =~ "All tests passed" ]]
}

@test "venv bootstrap: pytest not importable after install prints actionable error" {
  # Installs succeed but pytest is genuinely not among them — the bootstrap's
  # post-install `import pytest` check must fail loudly. ("six" is a tiny,
  # dependency-free package that installs fast.)
  echo "six>=1.0" > requirements.txt

  git add . && git commit -m "Initial commit" --quiet

  run _run_dev_test_gate

  # Should NOT print "Venv ready"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should mention pytest is not importable
  [[ "$output" =~ "pytest" ]] && [[ "$output" =~ "importable" ]]
}
